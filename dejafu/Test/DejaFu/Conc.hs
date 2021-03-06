{-# LANGUAGE CPP #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE TypeFamilies #-}

-- |
-- Module      : Test.DejaFu.Conc
-- Copyright   : (c) 2016--2018 Michael Walker
-- License     : MIT
-- Maintainer  : Michael Walker <mike@barrucadu.co.uk>
-- Stability   : experimental
-- Portability : CPP, FlexibleInstances, GeneralizedNewtypeDeriving, MultiParamTypeClasses, TypeFamilies
--
-- Deterministic traced execution of concurrent computations.
--
-- This works by executing the computation on a single thread, calling
-- out to the supplied scheduler after each step to determine which
-- thread runs next.
module Test.DejaFu.Conc
  ( -- * The @ConcT@ monad transformer
    ConcT
  , ConcIO

  -- * Executing computations
  , Failure(..)
  , MemType(..)
  , runConcurrent
  , subconcurrency
  , dontCheck

  -- ** Snapshotting

  -- $snapshotting_io

  , DCSnapshot
  , runForDCSnapshot
  , runWithDCSnapshot
  , canDCSnapshot
  , threadsFromDCSnapshot

  -- * Execution traces
  , Trace
  , Decision(..)
  , ThreadId(..)
  , ThreadAction(..)
  , Lookahead(..)
  , MVarId
  , CRefId
  , MaskingState(..)
  , showTrace
  , showFail

  -- * Scheduling
  , module Test.DejaFu.Schedule
  ) where

import           Control.Exception                   (MaskingState(..))
import qualified Control.Monad.Catch                 as Ca
import qualified Control.Monad.IO.Class              as IO
import           Control.Monad.Ref                   (MonadRef)
import qualified Control.Monad.Ref                   as Re
import           Control.Monad.Trans.Class           (MonadTrans(..))
import qualified Data.Foldable                       as F
import           Data.IORef                          (IORef)
import           Data.List                           (partition)
import qualified Data.Map.Strict                     as M
import           Data.Maybe                          (isNothing)
import           Test.DejaFu.Schedule

import qualified Control.Monad.Conc.Class            as C
import           Test.DejaFu.Conc.Internal
import           Test.DejaFu.Conc.Internal.Common
import           Test.DejaFu.Conc.Internal.STM
import           Test.DejaFu.Conc.Internal.Threading (Thread(_blocking),
                                                      Threads)
import           Test.DejaFu.Internal
import           Test.DejaFu.Types
import           Test.DejaFu.Utils

#if MIN_VERSION_base(4,9,0)
import qualified Control.Monad.Fail                  as Fail
#endif

-- | @since 0.6.0.0
newtype ConcT r n a = C { unC :: M n r a } deriving (Functor, Applicative, Monad)

#if MIN_VERSION_base(4,9,0)
-- | @since 0.9.1.0
instance Fail.MonadFail (ConcT r n) where
  fail = C . fail
#endif

-- | A 'MonadConc' implementation using @IO@.
--
-- @since 0.4.0.0
type ConcIO = ConcT IORef IO

toConc :: ((a -> Action n r) -> Action n r) -> ConcT r n a
toConc = C . cont

wrap :: (M n r a -> M n r a) -> ConcT r n a -> ConcT r n a
wrap f = C . f . unC

-- | @since 1.0.0.0
instance IO.MonadIO n => IO.MonadIO (ConcT r n) where
  liftIO ma = toConc (\c -> ALift (fmap c (IO.liftIO ma)))

instance Re.MonadRef (CRef r) (ConcT r n) where
  newRef a = toConc (ANewCRef "" a)

  readRef ref = toConc (AReadCRef ref)

  writeRef ref a = toConc (\c -> AWriteCRef ref a (c ()))

  modifyRef ref f = toConc (AModCRef ref (\a -> (f a, ())))

instance Re.MonadAtomicRef (CRef r) (ConcT r n) where
  atomicModifyRef ref f = toConc (AModCRef ref f)

instance MonadTrans (ConcT r) where
  lift ma = toConc (\c -> ALift (fmap c ma))

instance Ca.MonadCatch (ConcT r n) where
  catch ma h = toConc (ACatching (unC . h) (unC ma))

instance Ca.MonadThrow (ConcT r n) where
  throwM e = toConc (\_ -> AThrow e)

instance Ca.MonadMask (ConcT r n) where
  mask                mb = toConc (AMasking MaskedInterruptible   (\f -> unC $ mb $ wrap f))
  uninterruptibleMask mb = toConc (AMasking MaskedUninterruptible (\f -> unC $ mb $ wrap f))

#if MIN_VERSION_exceptions(0,10,0)
  generalBracket acquire release use = Ca.mask $ \unmasked -> do
    resource <- acquire
    b <- unmasked (use resource) `Ca.catch` (\e -> release resource (Ca.ExitCaseException e) >> Ca.throwM e)
    c <- release resource (Ca.ExitCaseSuccess b)
    pure (b, c)
#elif MIN_VERSION_exceptions(0,9,0)
  -- from https://github.com/fpco/stackage/issues/3315#issuecomment-368583481
  generalBracket acquire release cleanup use = Ca.mask $ \unmasked -> do
    resource <- acquire
    result <- unmasked (use resource) `Ca.catch` (\e -> cleanup resource e >> Ca.throwM e)
    _ <- release resource
    pure result
#endif

instance Monad n => C.MonadConc (ConcT r n) where
  type MVar     (ConcT r n) = MVar r
  type CRef     (ConcT r n) = CRef r
  type Ticket   (ConcT r n) = Ticket
  type STM      (ConcT r n) = S n r
  type ThreadId (ConcT r n) = ThreadId

  -- ----------

  forkWithUnmaskN   n ma = toConc (AFork   n (\umask -> runCont (unC $ ma $ wrap umask) (\_ -> AStop (pure ()))))
  forkOnWithUnmaskN n _  = C.forkWithUnmaskN n
  forkOSN n ma = forkOSWithUnmaskN n (const ma)

  isCurrentThreadBound = toConc AIsBound

  -- This implementation lies and returns 2 until a value is set. This
  -- will potentially avoid special-case behaviour for 1 capability,
  -- so it seems a sane choice.
  getNumCapabilities      = toConc AGetNumCapabilities
  setNumCapabilities caps = toConc (\c -> ASetNumCapabilities caps (c ()))

  myThreadId = toConc AMyTId

  yield = toConc (\c -> AYield (c ()))
  threadDelay n = toConc (\c -> ADelay n (c ()))

  -- ----------

  newCRefN n a = toConc (ANewCRef n a)

  readCRef   ref = toConc (AReadCRef    ref)
  readForCAS ref = toConc (AReadCRefCas ref)

  peekTicket' _ = _ticketVal

  writeCRef ref      a = toConc (\c -> AWriteCRef ref a (c ()))
  casCRef   ref tick a = toConc (ACasCRef ref tick a)

  atomicModifyCRef ref f = toConc (AModCRef    ref f)
  modifyCRefCAS    ref f = toConc (AModCRefCas ref f)

  -- ----------

  newEmptyMVarN n = toConc (ANewMVar n)

  putMVar  var a = toConc (\c -> APutMVar var a (c ()))
  readMVar var   = toConc (AReadMVar var)
  takeMVar var   = toConc (ATakeMVar var)

  tryPutMVar  var a = toConc (ATryPutMVar  var a)
  tryReadMVar var   = toConc (ATryReadMVar var)
  tryTakeMVar var   = toConc (ATryTakeMVar var)

  -- ----------

  throwTo tid e = toConc (\c -> AThrowTo tid e (c ()))

  -- ----------

  atomically = toConc . AAtom

-- move this into the instance defn when forkOSWithUnmaskN is added to MonadConc in 2018
forkOSWithUnmaskN :: Applicative n => String -> ((forall a. ConcT r n a -> ConcT r n a) -> ConcT r n ()) -> ConcT r n ThreadId
forkOSWithUnmaskN n ma
  | C.rtsSupportsBoundThreads = toConc (AForkOS n (\umask -> runCont (unC $ ma $ wrap umask) (\_ -> AStop (pure ()))))
  | otherwise = fail "RTS doesn't support multiple OS threads (use ghc -threaded when linking)"

-- | Run a concurrent computation with a given 'Scheduler' and initial
-- state, returning a failure reason on error. Also returned is the
-- final state of the scheduler, and an execution trace.
--
-- If the RTS supports bound threads (ghc -threaded when linking) then
-- the main thread of the concurrent computation will be bound, and
-- @forkOS@ / @forkOSN@ will work during execution.  If not, then the
-- main thread will not be found, and attempting to fork a bound
-- thread will raise an error.
--
-- __Warning:__ Blocking on the action of another thread in 'liftIO'
-- cannot be detected! So if you perform some potentially blocking
-- action in a 'liftIO' the entire collection of threads may deadlock!
-- You should therefore keep @IO@ blocks small, and only perform
-- blocking operations with the supplied primitives, insofar as
-- possible.
--
-- __Note:__ In order to prevent computation from hanging, the runtime
-- will assume that a deadlock situation has arisen if the scheduler
-- attempts to (a) schedule a blocked thread, or (b) schedule a
-- nonexistent thread. In either of those cases, the computation will
-- be halted.
--
-- @since 1.0.0.0
runConcurrent :: (C.MonadConc n, MonadRef r n)
  => Scheduler s
  -> MemType
  -> s
  -> ConcT r n a
  -> n (Either Failure a, s, Trace)
runConcurrent sched memtype s ma = do
  res <- runConcurrency False sched memtype s initialIdSource 2 (unC ma)
  out <- efromJust "runConcurrent" <$> Re.readRef (finalRef res)
  pure ( out
       , cSchedState (finalContext res)
       , F.toList (finalTrace res)
       )

-- | Run a concurrent computation and return its result.
--
-- This can only be called in the main thread, when no other threads
-- exist. Calls to 'subconcurrency' cannot be nested, or placed inside
-- a call to 'dontCheck'. Violating either of these conditions will
-- result in the computation failing with @IllegalSubconcurrency@.
-- The overall test-case can still succeed if the predicate allows for
-- a failing computation.
--
-- @since 0.6.0.0
subconcurrency :: ConcT r n a -> ConcT r n (Either Failure a)
subconcurrency ma = toConc (ASub (unC ma))

-- | Run an arbitrary action which gets some special treatment:
--
--  * For systematic testing, 'dontCheck' is not dependent with
--    anything, even if the action has dependencies.
--
--  * For pre-emption bounding, 'dontCheck' counts for zero
--    pre-emptions, even if the action performs pre-emptive context
--    switches.
--
--  * For fair bounding, 'dontCheck' counts for zero yields/delays,
--    even if the action performs yields or delays.
--
--  * For length bounding, 'dontCheck' counts for one step, even if
--    the action has many.
--
--   * All SCT functions use 'runForDCSnapshot' / 'runWithDCSnapshot'
--     to ensure that the action is only executed once, although you
--     should be careful with @IO@ (see note on snapshotting @IO@).
--
-- The action is executed atomically with a deterministic scheduler
-- under sequential consistency.  Any threads created inside the
-- action continue to exist in the main computation.
--
-- This must be the first thing done in the main thread.  Violating
-- this condition will result in the computation failing with
-- @IllegalDontCheck@.  The overall test-case can still succeed if the
-- predicate allows for a failing computation.
--
-- If the action fails (deadlock, length bound exceeded, etc), the
-- whole computation fails.
--
-- @since 1.1.0.0
dontCheck
  :: Maybe Int
  -- ^ An optional length bound.
  -> ConcT r n a
  -- ^ The action to execute.
  -> ConcT r n a
dontCheck lb ma = toConc (ADontCheck lb (unC ma))

-------------------------------------------------------------------------------
-- Snapshotting

-- $snapshotting_io
--
-- __Snapshotting @IO@:__ A snapshot captures entire state of your
-- concurrent program: the state of every thread, the number of
-- capabilities, the values of any @CRef@s, @MVar@s, and @TVar@s, and
-- records any @IO@ that you performed.
--
-- When restoring a snapshot this @IO@ is replayed, in order.  But the
-- whole snapshotted computation is not.  So the effects of the @IO@
-- take place again, but any return values are ignored.  For example,
-- this program will not do what you want:
--
-- @
-- bad_snapshot = do
--   r <- dontCheck Nothing $ do
--     r <- liftIO (newIORef 0)
--     liftIO (modifyIORef r (+1))
--     pure r
--   liftIO (readIORef r)
-- @
--
-- When the snapshot is taken, the value in the @IORef@ will be 1.
-- When the snapshot is restored for the first time, those @IO@
-- actions will be run again, /but their return values will be discarded/.
-- The value in the @IORef@ will be 2.  When the snapshot
-- is restored for the second time, the value in the @IORef@ will be
-- 3.  And so on.
--
-- To safely use @IO@ in a snapshotted computation, __the combined effect must be idempotent__.
-- You should either use actions which set the state to the final
-- value directly, rather than modifying it (eg, using a combination
-- of @liftIO . readIORef@ and @liftIO . writeIORef@ here), or reset
-- the state to a known value.  Both of these approaches will work:
--
-- @
-- good_snapshot1 = do
--   r <- dontCheck Nothing $ do
--     let modify r f = liftIO (readIORef r) >>= liftIO . writeIORef r . f
--     r <- liftIO (newIORef 0)
--     modify r (+1)
--     pure r
--   liftIO (readIORef r)
--
-- good_snapshot2 = do
--   r <- dontCheck Nothing $ do
--     r <- liftIO (newIORef 0)
--     liftIO (writeIORef r 0)
--     liftIO (modifyIORef r (+1))
--     pure r
--   liftIO (readIORef r)
-- @

-- | Like 'runConcurrent', but terminates immediately after running
-- the 'dontCheck' action with a 'DCSnapshot' which can be used in
-- 'runWithDCSnapshot' to avoid doing that work again.
--
-- If this program does not contain a legal use of 'dontCheck', then
-- the result will be @Nothing@.
--
-- If you are using the SCT functions on an action which contains a
-- 'dontCheck', snapshotting will be handled for you, without you
-- needing to call this function yourself.
--
-- @since 1.1.0.0
runForDCSnapshot :: (C.MonadConc n, MonadRef r n)
  => ConcT r n a
  -> n (Maybe (Either Failure (DCSnapshot r n a), Trace))
runForDCSnapshot ma = do
  res <- runConcurrency True roundRobinSchedNP SequentialConsistency () initialIdSource 2 (unC ma)
  out <- Re.readRef (finalRef res)
  pure $ case (finalRestore res, out) of
    (Just _, Just (Left f)) -> Just (Left f, F.toList (finalTrace res))
    (Just restore, _) -> Just (Right (DCSnapshot (finalContext res) restore (finalRef res)), F.toList (finalTrace res))
    (_, _) -> Nothing

-- | Like 'runConcurrent', but uses a 'DCSnapshot' produced by
-- 'runForDCSnapshot' to skip the 'dontCheck' work.
--
-- If you are using the SCT functions on an action which contains a
-- 'dontCheck', snapshotting will be handled for you, without you
-- needing to call this function yourself.
--
-- @since 1.1.0.0
runWithDCSnapshot :: (C.MonadConc n, MonadRef r n)
  => Scheduler s
  -> MemType
  -> s
  -> DCSnapshot r n a
  -> n (Either Failure a, s, Trace)
runWithDCSnapshot sched memtype s snapshot = do
  let context = (dcsContext snapshot) { cSchedState = s }
  let restore = dcsRestore snapshot
  let ref = dcsRef snapshot
  res <- runConcurrencyWithSnapshot sched memtype context restore ref
  out <- efromJust "runWithDCSnapshot" <$> Re.readRef (finalRef res)
  pure ( out
       , cSchedState (finalContext res)
       , F.toList (finalTrace res)
       )

-- | Check if a 'DCSnapshot' can be taken from this computation.
--
-- @since 1.1.0.0
canDCSnapshot :: ConcT r n a -> Bool
canDCSnapshot (C (M k)) = lookahead (k undefined) == WillDontCheck

-- | Get the threads which exist in a snapshot, partitioned into
-- runnable and not runnable.
--
-- @since 1.1.0.0
threadsFromDCSnapshot :: DCSnapshot r n a -> ([ThreadId], [ThreadId])
threadsFromDCSnapshot snapshot = partition isRunnable (M.keys threads) where
  threads = cThreads (dcsContext snapshot)
  isRunnable tid = isNothing (_blocking =<< M.lookup tid threads)
