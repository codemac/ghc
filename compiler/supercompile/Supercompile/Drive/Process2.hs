{-# LANGUAGE GADTs, RankNTypes #-}
module Supercompile.Drive.Process2 (supercompile) where

import Supercompile.Drive.Match
import Supercompile.Drive.Split
import Supercompile.Drive.Process

import Supercompile.Core.FreeVars
import Supercompile.Core.Renaming
import Supercompile.Core.Syntax
import Supercompile.Core.Tag

import Supercompile.Evaluator.Deeds
import Supercompile.Evaluator.Residualise
import Supercompile.Evaluator.Syntax

import Supercompile.Termination.TagBag (stateTags)
import Supercompile.Termination.Combinators

import Supercompile.Utilities

import Id         (mkLocalId)
import Name       (Name, mkSystemVarName)
import FastString (mkFastString)
import Util       (sndOf3)
import CoreUtils  (mkPiTypes)
import qualified State as State

import qualified Data.Map as M
import Data.Monoid (mempty)


data Stream a = a :< Stream a

listToStream :: [a] -> Stream a
listToStream []     = error "listToStream"
listToStream (x:xs) = x :< listToStream xs


data LeafTy a

data DelayStructure sh f where
    Leaf   :: f a -> DelayStructure (LeafTy a) f
    Branch :: DelayStructure sh1 f -> DelayStructure sh2 f -> DelayStructure (sh1, sh2) f


--newtype I a = I { unI :: a }
newtype QM m a = QM { unQM :: m (DelayM m a) }

-- If you don't want DelayM to have Monad structure, you can nuke the nested use of DelayM,
-- and make some of the consumers simpler. I actually want this generalisation, though.
data DelayM m r = Done r
                | forall sh. Delayed (DelayStructure sh (QM m)) (DelayStructure sh Identity -> DelayM m r)

instance Functor (DelayM m) where
    fmap f x = pure f <*> x

instance Applicative (DelayM m) where
    pure = return
    Done f         <*> Done x         = Done (f x)
    Delayed qs k   <*> Done x         = Delayed qs (\as -> k as <*> Done x)
    Done f         <*> Delayed qs k   = Delayed qs (\as -> Done f <*> k as)
    Delayed qs1 k1 <*> Delayed qs2 k2 = Delayed (Branch qs1 qs2) (\(Branch as1 as2) -> k1 as1 <*> k2 as2)

instance Monad (DelayM m) where
    return = Done
    Done x       >>= fxmy = fxmy x
    Delayed qs k >>= fxmy = Delayed qs (\as -> k as >>= fxmy)

delay :: m (DelayM m a) -> DelayM m a
delay q = Delayed (Leaf (QM q)) (\(Leaf (I a)) -> pure a)

runDelayM :: (Applicative m, Monad m)
          => (DelayM m r -> DelayM m r) -- ^ Chooses the evaluation strategy
          -> DelayM m r -> m r
runDelayM choose_some = go
  where
    go = go' . choose_some
    
    go' (Done x)       = pure x
    go' (Delayed qs k) = mungeDS qs >>= \mx -> go (mx >>= k)

fmapNT :: Applicative m
       => (forall a. f a -> m (g a))
       -> DelayStructure sh f
       -> m (DelayStructure sh g)
fmapNT f (Leaf x)         = fmap Leaf (f x)
fmapNT f (Branch qs1 qs2) = liftA2 Branch (fmapNT f qs1) (fmapNT f qs2)

mungeDS :: Applicative n
        => DelayStructure sh (QM n)
        -> n (DelayM n (DelayStructure sh Identity))
mungeDS = unComp . fmapNT (Comp . fmap (fmap I) . unQM)
{-
mungeDS (Leaf (QM mx))   = fmap (fmap (Leaf . I)) mx
mungeDS (Branch qs1 qs2) = liftA2 (liftA2 Branch) (mungeDS qs1) (mungeDS qs2)
-}

delayDS :: DelayStructure sh (QM n)
        -> DelayM n (DelayStructure sh Identity)
delayDS = fmapNT (fmap I . delay . unQM)
{-
delayDS (Leaf (QM mx))   = fmap (Leaf . I) (delay mx)
delayDS (Branch qs1 qs2) = liftA2 Branch (delayDS qs1) (delayDS qs2)
-}

depthFirst :: DelayM m r -> DelayM m r
depthFirst (Done x)       = Done x
depthFirst (Delayed qs k) = delayTail qs >>= k
  where
    delayTail :: DelayStructure sh (QM m) -> DelayM m (DelayStructure sh Identity)
    delayTail (Leaf (QM q))    = fmap (Leaf . I) (delay q)
    delayTail (Branch qs1 qs2) = liftM2 Branch (delayTail qs1) (delayDS qs2)

breadthFirst :: DelayM m r -> DelayM m r
breadthFirst = id


class MonadTrans t where
    lift :: Monad m => m a -> t m a


newtype StateT s m a = StateT { unStateT :: s -> m (a, s) }

instance Functor m => Functor (StateT s m) where
    fmap f mx = StateT $ \s -> fmap (first f) (unStateT mx s)

instance (Functor m, Monad m) => Applicative (StateT s m) where
    pure = return
    (<*>) = ap

instance Monad m => Monad (StateT s m) where
    return x = StateT $ \s -> return (x, s)
    mx >>= fxmy = StateT $ \s -> unStateT mx s >>= \(x, s) -> unStateT (fxmy x) s

instance MonadTrans (StateT s) where
    lift mx = StateT $ \s -> liftM (flip (,) s) mx

delayStateT :: Functor m
            => (forall a. m (n a) -> n a)
            -> m (StateT s n a) -> StateT s n a
delayStateT delay mx = StateT $ \s -> delay (fmap (($ s) . unStateT) mx)

{-
-- NB: you can't implement this for all monad transformers
-- (in particular the continuation monad transformer).
-- But if you can, we can derive a delayStateT equivalent from it:
fiddle :: (forall b. m b -> n b)
       -> StateT s m a -> StateT s n a
fiddle f mx = ST $ \s -> f (unStateT mx s)


lifty :: Monad m => m a -> DelayM m a
lifty = delay . liftM return

mx                                  :: m (StateT s (DelayM m) a)
liftStateT mx                       :: StateT s m (StateT s (DelayM m) a)
fiddle lifty                        :: forall a. Monad m => StateT s m a -> StateT s (DelayM m) a
fiddle lifty (liftStateT mx)        :: Monad m => StateT s (DelayM m) (StateT s (DelayM m) a)
join (fiddle lifty (liftStateT mx)) :: Monad m => StateT s (DelayM m) a

Therefore:

delayStateT :: Monad m => m (StateT s (DelayM m) a) -> StateT s (DelayM m) a
delayStateT = join . fiddle lifty . liftStateT
-}


newtype ContT r m a = ContT { unContT :: (a -> m r) -> m r }

instance Functor (ContT r m) where
    fmap f mx = ContT $ \k -> unContT mx (k . f)

instance Applicative (ContT r m) where
    pure = return
    (<*>) = ap

instance Monad (ContT r m) where
    return x = ContT $ \k -> k x
    mx >>= fxmy = ContT $ \k -> unContT mx $ \x -> unContT (fxmy x) k

instance MonadTrans (ContT r) where
    lift mx = ContT $ \k -> mx >>= k

runContT :: Monad m => ContT r m r -> m r
runContT mx = unContT mx return

callCC :: ((forall b. a -> ContT r m b) -> ContT r m a) -> ContT r m a
callCC f = ContT $ \k -> unContT (f (\a -> ContT $ \_k -> k a)) k


newtype ReaderT r m a = ReaderT { unReaderT :: r -> m a }

instance Functor m => Functor (ReaderT r m) where
    fmap f mx = ReaderT $ \r -> fmap f (unReaderT mx r)

instance Applicative m => Applicative (ReaderT r m) where
    pure x = ReaderT $ \_ -> pure x
    mf <*> mx = ReaderT $ \r -> unReaderT mf r <*> unReaderT mx r

instance Monad m => Monad (ReaderT r m) where
    return x = ReaderT $ \_ -> return x
    mx >>= fxmy = ReaderT $ \r -> unReaderT mx r >>= \x -> unReaderT (fxmy x) r

instance MonadTrans (ReaderT r) where
    lift mx = ReaderT $ \_ -> mx

delayReaderT :: Functor m
             => (forall a. m (n a) -> n a)
            -> m (ReaderT r n a) -> ReaderT r n a
delayReaderT delay mx = ReaderT $ \r -> delay (fmap (($ r) . unReaderT) mx)

runReaderT :: r -> ReaderT r m a -> m a
runReaderT = flip unReaderT

liftCallCCReaderT :: (((forall b. a -> m b)           -> m a)           -> m a)
                  ->  ((forall b. a -> ReaderT r m b) -> ReaderT r m a) -> ReaderT r m a
liftCallCCReaderT call_cc f = ReaderT $ \r -> call_cc $ \c -> runReaderT r (f (ReaderT . const . c))


newtype RollbackScpM = RB { doRB :: forall c. LevelM (Deeds, Out FVedTerm) -> ProcessM c }


type ProcessHistory = GraphicalHistory (NodeKey, (State, RollbackScpM)) -- TODO: GraphicalHistory

pROCESS_HISTORY :: ProcessHistory
pROCESS_HISTORY = mkGraphicalHistory (cofmap fst wQO)

type HistoryEnvM = (->) ProcessHistory

runHistoryEnvM :: HistoryEnvM a -> a
runHistoryEnvM = flip ($) pROCESS_HISTORY

type HistoryThreadM = State.State ProcessHistory

withHistory :: (ProcessHistory -> (ProcessHistory, a)) -> HistoryThreadM a
withHistory f = State.state (swap . f)
  where swap = uncurry (flip (,))

runHistoryThreadM :: HistoryThreadM a -> a
runHistoryThreadM = flip State.evalState pROCESS_HISTORY


type Parent = NodeKey

terminateM :: Parent -> State -> RollbackScpM -> (Parent -> a) -> (Parent -> State -> RollbackScpM -> ProcessM a) -> ProcessM a
terminateM parent state rb k_continue k_stop = withHistory' $ \hist -> trace (show hist) $ case terminate hist (parent, (state, rb)) of
    Continue hist'                                     -> return (hist', k_continue (generatedKey hist'))
    Stop (shallow_parent, (shallow_state, shallow_rb)) -> liftM ((,) hist) $ k_stop shallow_parent shallow_state shallow_rb
  where
    withHistory' :: (ProcessHistory -> ProcessM (ProcessHistory, a)) -> ProcessM a
    withHistory' act = lift State.get >>= \hist -> act hist >>= \(hist', x) -> lift (State.put hist') >> return x


data Promise = P {
    fun        :: Var,      -- Name assigned in output program
    abstracted :: [AbsVar], -- Abstracted over these variables
    meaning    :: State     -- Minimum adequate term
  }

data MemoState = MS {
    promises :: [Promise],
    hNames   :: Stream Name
  }

type MemoT = StateT MemoState

runMemoT :: Functor m => MemoT m a -> m a
runMemoT mx = fmap fst $ unStateT mx MS { promises = [], hNames = h_names }
  where h_names = listToStream $ zipWith (\i uniq -> mkSystemVarName uniq (mkFastString ('h' : show (i :: Int))))
                                         [1..] (uniqsFromSupply hFunctionsUniqSupply)


newtype FulfilmentState = FS {
    fulfilments :: [(Var, FVedTerm)]
  }

type FulfilmentT = StateT FulfilmentState

fulfill :: Monad m => Promise -> (Deeds, FVedTerm) -> FulfilmentT m (Deeds, FVedTerm)
fulfill p (deeds, e_body) = StateT $ \fs -> return ((deeds, e_body), FS { fulfilments = (fun p, tyVarIdLambdas (abstracted p) e_body) : fulfilments fs })

runFulfilmentT :: Monad m => FulfilmentT m FVedTerm -> m FVedTerm
runFulfilmentT mx = liftM (\(e, fs) -> letRec (fulfilments fs) e) $ unStateT mx (FS { fulfilments = [] })


promise :: State -> MemoState -> (Promise, MemoState)
promise state ms = (p, ms')
  where vs_list = stateAbsVars state
        h_name :< h_names' = hNames ms
        x = mkLocalId h_name (vs_list `mkPiTypes` stateType state)
        p = P {
            fun        = x,
            abstracted = vs_list,
            meaning    = state
          }
        ms' = MS {
            promises = p : promises ms,
            hNames   = h_names'
          }

instance MonadStatics LevelM where
    --bindCapturedFloats fvs mx | isEmptyVarSet fvs = liftM ((,) []) mx
    --                          | otherwise         = pprPanic "bindCapturedFloats: does not support statics" (ppr fvs)
    bindCapturedFloats _fvs mx = liftM ((,) []) mx -- FIXME: do something other than hope for the best
    monitorFVs = liftM ((,) emptyVarSet)

memo :: (Applicative t, Functor m, Monad m)
     => (State -> t (FulfilmentT m (Deeds, Out FVedTerm)))
     -> State -> MemoT t (FulfilmentT m (Deeds, Out FVedTerm))
memo opt state = StateT $ \ms -> traceRenderScpM "memo" state *>
     -- NB: If tb contains a dead PureHeap binding (hopefully impossible) then it may have a free variable that
     -- I can't rename, so "rename" will cause an error. Not observed in practice yet.
    case [ (p, (releaseStateDeed state, var (fun p) `applyAbsVars` map (renameAbsVar rn_lr) (abstracted p)))
         | p <- promises ms
         , Just rn_lr <- [(\res -> if isNothing res then pprTraceSC "no match:" (ppr (fun p)) res else res) $
                          match (meaning p) state]
         ] of (p, res):_ -> pure $ (do { traceRenderScpM "=sc" (fun p, PrettyDoc (pPrintFullState True state), res)
                                       ; return res }, ms)
              _          -> flip fmap (opt state) $ \mres ->
                                   (do { traceRenderScpM ">sc" (fun p, PrettyDoc (pPrintFullState True state))
                                       ; res <- mres
                                       ; traceRenderScpM "<sc" (fun p, PrettyDoc (pPrintFullState False state), res)
                                       ; fulfill p res }, ms')
                where (p, ms') = promise state ms


type SpecT = ReaderT AlreadySpeculated

runSpecT :: SpecT m a -> m a
runSpecT = runReaderT nothingSpeculated

speculated :: State -> (State -> SpecT m a) -> SpecT m a
speculated s k = ReaderT $ \already -> case speculate already (mempty, s) of (already, (_stats, s')) -> unReaderT (k s') already

liftSpeculatedStateT :: (forall a. State -> (State -> m a)        -> m a)
                     ->  State -> (State -> StateT s m a) -> StateT s m a
liftSpeculatedStateT speculated state k = StateT $ \s -> speculated state (\state' -> unStateT (k state') s)


type LevelM = FulfilmentT (SpecT ScpM)

-- NB: monads *within* the ContT are persistent over a rollback. Ones outside get reset.
type ProcessM = ContT (Out FVedTerm) HistoryThreadM
type ScpM = DelayM (MemoT ProcessM)

traceRenderScpM :: (Outputable a, Applicative t) => String -> a -> t ()
traceRenderScpM msg x = pprTraceSC msg (pPrint x) $ pure () -- TODO: include depth, refine to ScpM monad only

runScpM :: (Applicative m, Monad m) => m (DelayM m a) -> m a
runScpM mx = mx >>= runDelayM eval_strat
  where
    -- Doing things this way prevents GHC bleating about depthFirst being unused
    eval_strat | False     = depthFirst
               | otherwise = breadthFirst


sc' :: Parent -> State -> ProcessM (LevelM (Deeds, Out FVedTerm))
sc' parent state = callCC (\k -> try (RB k))
  where
    trce how shallow_state = pprTraceSC ("sc-stop(" ++ how ++ ")") (ppr (stateTags shallow_state) <+> text "<|" <+> ppr (stateTags state) $$
                                                                    ppr shallow_state $$ pPrintFullState True shallow_state $$ ppr state $$ pPrintFullState True state)
    try :: RollbackScpM -> ProcessM (LevelM (Deeds, Out FVedTerm))
    try rb = terminateM parent state rb
               (\parent -> liftSpeculatedStateT speculated state $ \state' -> split (reduce state') (delayStateT (delayReaderT delay) . sc parent))
               -- (\_ shallow_state _ -> return $ maybe (trce "split" shallow_state $ split state) (trce "gen" shallow_state) (generalise (mK_GENERALISER shallow_state state) state) (delayStateT (delayReaderT delay) . sc parent))
               (\shallow_parent shallow_state shallow_rb -> trace "rb" $ doRB shallow_rb (maybe (trce "split" shallow_state $ split shallow_state) (trce "gen" shallow_state) (generalise (mK_GENERALISER shallow_state state) shallow_state) (delayStateT (delayReaderT delay) . sc shallow_parent)))

sc :: Parent -> State -> MemoT ProcessM (LevelM (Deeds, Out FVedTerm))
sc parent = memo (sc' parent) . gc -- Garbage collection necessary because normalisation might have made some stuff dead


supercompile :: M.Map Var Term -> Term -> Term
supercompile unfoldings e = fVedTermToTerm $ runHistoryThreadM $ runContT $ runMemoT $ runScpM $ liftM (runSpecT . runFulfilmentT . fmap snd) $ sc 0 state
  where state = prepareTerm unfoldings e