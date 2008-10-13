
module CmmContFlowOpt
    ( runCmmOpts, cmmCfgOpts, cmmCfgOptsZ
    , branchChainElimZ, removeUnreachableBlocksZ, predMap
    , replaceLabelsZ, replaceBranches, runCmmContFlowOptsZs
    )
where

import BlockId
import Cmm
import CmmTx
import qualified ZipCfg as G
import ZipCfg
import ZipCfgCmmRep

import Maybes
import Monad
import Outputable
import Panic
import Prelude hiding (unzip, zip)
import Util

------------------------------------
runCmmContFlowOptsZs :: [CmmZ] -> [CmmZ]
runCmmContFlowOptsZs prog
  = [ runTx (runCmmOpts cmmCfgOptsZ) cmm_top
    | cmm_top <- prog ]

cmmCfgOpts  :: Tx (ListGraph CmmStmt)
cmmCfgOptsZ :: Tx CmmGraph

cmmCfgOpts  = branchChainElim  -- boring, but will get more exciting later
cmmCfgOptsZ g =
    (branchChainElimZ `seqTx` blockConcatZ `seqTx` removeUnreachableBlocksZ) g
        -- Here branchChainElim can ultimately be replaced
        -- with a more exciting combination of optimisations

runCmmOpts :: Tx g -> Tx (GenCmm d h g)
runCmmOpts opt = mapProcs (optGraph opt)

optGraph :: Tx g -> Tx (GenCmmTop d h g)
optGraph _   top@(CmmData {}) = noTx top
optGraph opt (CmmProc info lbl formals g) = fmap (CmmProc info lbl formals) (opt g)

------------------------------------
mapProcs :: Tx (GenCmmTop d h s) -> Tx (GenCmm d h s)
mapProcs f (Cmm tops) = fmap Cmm (mapTx f tops)

----------------------------------------------------------------
branchChainElim :: Tx (ListGraph CmmStmt)
-- If L is not captured in an instruction, we can remove any
-- basic block of the form L: goto L', and replace L with L' everywhere else.
-- How does L get captured? In a CallArea.
branchChainElim (ListGraph blocks)
  | null lone_branch_blocks     -- No blocks to remove
  = noTx (ListGraph blocks)
  | otherwise
  = aTx (ListGraph new_blocks)
  where
    (lone_branch_blocks, others) = partitionWith isLoneBranch blocks
    new_blocks = map (replaceLabels env) others
    env = mkClosureBlockEnv lone_branch_blocks

isLoneBranch :: CmmBasicBlock -> Either (BlockId, BlockId) CmmBasicBlock
isLoneBranch (BasicBlock id [CmmBranch target]) | id /= target = Left (id, target)
isLoneBranch other_block                                       = Right other_block
   -- An infinite loop is not a link in a branch chain!

replaceLabels :: BlockEnv BlockId -> CmmBasicBlock -> CmmBasicBlock
replaceLabels env (BasicBlock id stmts)
  = BasicBlock id (map replace stmts)
  where
    replace (CmmBranch id)       = CmmBranch (lookup id)
    replace (CmmCondBranch e id) = CmmCondBranch e (lookup id)
    replace (CmmSwitch e tbl)    = CmmSwitch e (map (fmap lookup) tbl)
    replace other_stmt           = other_stmt

    lookup id = lookupBlockEnv env id `orElse` id 
----------------------------------------------------------------
branchChainElimZ :: Tx CmmGraph
-- Remove any basic block of the form L: goto L',
-- and replace L with L' everywhere else
branchChainElimZ g@(G.LGraph eid args _)
  | null lone_branch_blocks     -- No blocks to remove
  = noTx g
  | otherwise
  = aTx $ replaceLabelsZ env $ G.of_block_list eid args (self_branches ++ others)
  where
    (lone_branch_blocks, others) = partitionWith isLoneBranchZ (G.to_block_list g)
    env = mkClosureBlockEnvZ lone_branch_blocks
    self_branches =
      let loop_to (id, _) =
            if lookup id == id then
              Just (G.Block id emptyStackInfo (G.ZLast (G.mkBranchNode id)))
            else
              Nothing
      in  mapMaybe loop_to lone_branch_blocks
    lookup id = lookupBlockEnv env id `orElse` id 

-- Be careful not to mark a block as a lone branch if it carries
-- important information about incoming arguments or the update frame.
isLoneBranchZ :: CmmBlock -> Either (BlockId, BlockId) CmmBlock
isLoneBranchZ (G.Block id (StackInfo {argBytes = Nothing, returnOff = Nothing})
              (G.ZLast (G.LastOther (LastBranch target))))
    | id /= target  = Left (id,target)
isLoneBranchZ other = Right other
   -- An infinite loop is not a link in a branch chain!

replaceLabelsZ :: BlockEnv BlockId -> CmmGraph -> CmmGraph
replaceLabelsZ env = replace_eid . G.map_nodes id middle last
  where
    replace_eid (G.LGraph eid off blocks) = G.LGraph (lookup eid) off blocks
    middle = mapExpDeepMiddle exp
    last l = mapExpDeepLast   exp (last' l)
    last' (LastBranch bid) = LastBranch (lookup bid)
    last' (LastCondBranch p t f) = LastCondBranch p (lookup t) (lookup f)
    last' (LastSwitch e arms) = LastSwitch e (map (liftM lookup) arms)
    last' (LastCall t k a r) = LastCall t (liftM lookup k) a r
    exp (CmmLit (CmmBlock bid)) = CmmLit (CmmBlock (lookup bid))
    exp   (CmmStackSlot (CallArea (Young id)) i) =
      CmmStackSlot (CallArea (Young (lookup id))) i
    exp e = e
    lookup id = fmap lookup (lookupBlockEnv env id) `orElse` id 

replaceBranches :: BlockEnv BlockId -> CmmGraph -> CmmGraph
replaceBranches env g = map_nodes id id last g
  where
    last (LastBranch id)          = LastBranch (lookup id)
    last (LastCondBranch e ti fi) = LastCondBranch e (lookup ti) (lookup fi)
    last (LastSwitch e tbl)       = LastSwitch e (map (fmap lookup) tbl)
    last l@(LastCall {})          = l
    lookup id = fmap lookup (lookupBlockEnv env id) `orElse` id 

----------------------------------------------------------------
-- Build a map from a block to its set of predecessors. Very useful.
predMap :: G.LastNode l => G.LGraph m l -> BlockEnv BlockSet
predMap g = G.fold_blocks add_preds emptyBlockEnv g -- find the back edges
  where add_preds b env = foldl (add b) env (G.succs b)
        add (G.Block bid _ _) env b' =
          extendBlockEnv env b' $
                extendBlockSet (lookupBlockEnv env b' `orElse` emptyBlockSet) bid
----------------------------------------------------------------
-- If a block B branches to a label L, and L has no other predecessors,
-- then we can splice the block starting with L onto the end of B.
-- Because this optmization can be inhibited by unreachable blocks,
-- we first take a pass to drops unreachable blocks.
-- Order matters, so we work bottom up (reverse postorder DFS).
--
-- To ensure correctness, we have to make sure that the BlockId of the block
-- we are about to eliminate is not named in another instruction.
--
-- Note: This optimization does _not_ subsume branch chain elimination.
blockConcatZ  :: Tx CmmGraph
blockConcatZ = removeUnreachableBlocksZ `seqTx` blockConcatZ'
blockConcatZ' :: Tx CmmGraph
blockConcatZ' g@(G.LGraph eid off blocks) =
  tx $ replaceLabelsZ concatMap $ G.LGraph eid off blocks'
  where (changed, blocks', concatMap) =
           foldr maybe_concat (False, blocks, emptyBlockEnv) $ G.postorder_dfs g
        maybe_concat b@(G.Block bid _ _) (changed, blocks', concatMap) =
          let unchanged = (changed, extendBlockEnv blocks' bid b, concatMap)
          in case G.goto_end $ G.unzip b of
               (h, G.LastOther (LastBranch b')) ->
                  if canConcatWith b' then
                    (True, extendBlockEnv blocks' bid $ splice blocks' h b',
                     extendBlockEnv concatMap b' bid)
                  else unchanged
               _ -> unchanged
        num_preds bid = liftM sizeBlockSet (lookupBlockEnv backEdges bid) `orElse` 0
        canConcatWith b' =
          case lookupBlockEnv blocks b' of
            Just (G.Block _ (StackInfo {returnOff = Nothing}) _) -> num_preds b' == 1
            _ -> False
        backEdges = predMap g
        splice blocks' h bid' =
          case lookupBlockEnv blocks' bid' of
            Just (G.Block _ (StackInfo {returnOff = Nothing}) t) ->
              G.zip $ G.ZBlock h t
            Just (G.Block _ _ _) ->
              panic "trying to concatenate but successor block has incoming args"
            Nothing -> pprPanic "unknown successor block" (ppr bid' <+> ppr blocks' <+> ppr blocks)
        tx = if changed then aTx else noTx
----------------------------------------------------------------
mkClosureBlockEnv :: [(BlockId, BlockId)] -> BlockEnv BlockId
mkClosureBlockEnv blocks = mkBlockEnv $ map follow blocks
    where singleEnv = mkBlockEnv blocks
          follow (id, next) = (id, endChain id next)
          endChain orig id = case lookupBlockEnv singleEnv id of
                               Just id' | id /= orig -> endChain orig id'
                               _ -> id
mkClosureBlockEnvZ :: [(BlockId, BlockId)] -> BlockEnv BlockId
mkClosureBlockEnvZ blocks = mkBlockEnv $ map follow blocks
    where singleEnv = mkBlockEnv blocks
          follow (id, next) = (id, endChain id next)
          endChain orig id = case lookupBlockEnv singleEnv id of
                               Just id' | id /= orig -> endChain orig id'
                               _ -> id
----------------------------------------------------------------
removeUnreachableBlocksZ :: Tx CmmGraph
removeUnreachableBlocksZ g@(G.LGraph id off blocks) =
  if length blocks' < sizeBEnv blocks then aTx $ G.of_block_list id off blocks'
  else noTx g
    where blocks' = G.postorder_dfs g
