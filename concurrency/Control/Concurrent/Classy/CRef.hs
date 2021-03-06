-- |
-- Module      : Control.Concurrent.Classy.CRef
-- Copyright   : (c) 2016 Michael Walker
-- License     : MIT
-- Maintainer  : Michael Walker <mike@barrucadu.co.uk>
-- Stability   : stable
-- Portability : portable
--
-- Mutable references in a concurrency monad.
--
-- __Deviations:__ There is no @Eq@ instance for @MonadConc@ the
-- @CRef@ type. Furthermore, the @mkWeakIORef@ function is not
-- provided.
module Control.Concurrent.Classy.CRef
  ( -- * CRefs
    newCRef
  , readCRef
  , writeCRef
  , modifyCRef
  , modifyCRef'
  , atomicModifyCRef
  , atomicModifyCRef'
  , atomicWriteCRef

  -- * Memory Model

  -- | In a concurrent program, @CRef@ operations may appear
  -- out-of-order to another thread, depending on the memory model of
  -- the underlying processor architecture. For example, on x86 (which
  -- uses total store order), loads can move ahead of stores. Consider
  -- this example:
  --
  -- > crefs :: MonadConc m => m (Bool, Bool)
  -- > crefs = do
  -- >   r1 <- newCRef False
  -- >   r2 <- newCRef False
  -- >
  -- >   x <- spawn $ writeCRef r1 True >> readCRef r2
  -- >   y <- spawn $ writeCRef r2 True >> readCRef r1
  -- >
  -- >   (,) <$> readMVar x <*> readMVar y
  --
  -- Under a sequentially consistent memory model the possible results
  -- are @(True, True)@, @(True, False)@, and @(False, True)@. Under
  -- total or partial store order, @(False, False)@ is also a possible
  -- result, even though there is no interleaving of the threads which
  -- can lead to this.
  --
  -- We can see this by testing with different memory models:
  --
  -- > > autocheckWay defaultWay SequentialConsistency relaxed
  -- > [pass] Never Deadlocks
  -- > [pass] No Exceptions
  -- > [fail] Consistent Result
  -- >        (False,True) S0---------S1----S0--S2----S0--
  -- >
  -- >        (True,True) S0---------S1-P2----S1---S0---
  -- >
  -- >        (True,False) S0---------S2----S1----S0---
  -- > False
  --
  -- > > autocheckWay defaultWay TotalStoreOrder  relaxed
  -- > [pass] Never Deadlocks
  -- > [pass] No Exceptions
  -- > [fail] Consistent Result
  -- >         (False,True) S0---------S1----S0--S2----S0--
  -- >
  -- >         (False,False) S0---------S1--P2----S1--S0---
  -- >
  -- >         (True,False) S0---------S2----S1----S0---
  -- >
  -- >         (True,True) S0---------S1-C-S2----S1---S0---
  -- > False
  --
  -- Traces for non-sequentially-consistent memory models show where
  -- writes to @CRef@s are /committed/, which makes a write visible to
  -- all threads rather than just the one which performed the
  -- write. Only 'writeCRef' is broken up into separate write and
  -- commit steps, 'atomicModifyCRef' is still atomic and imposes a
  -- memory barrier.
  ) where

import           Control.Monad.Conc.Class

-- | Mutate the contents of a @CRef@.
--
-- Be warned that 'modifyCRef' does not apply the function strictly.
-- This means if the program calls 'modifyCRef' many times, but
-- seldomly uses the value, thunks will pile up in memory resulting in
-- a space leak. This is a common mistake made when using a @CRef@ as
-- a counter. For example, the following will likely produce a stack
-- overflow:
--
-- >ref <- newCRef 0
-- >replicateM_ 1000000 $ modifyCRef ref (+1)
-- >readCRef ref >>= print
--
-- To avoid this problem, use 'modifyCRef'' instead.
--
-- @since 1.0.0.0
modifyCRef :: MonadConc m => CRef m a -> (a -> a) -> m ()
modifyCRef ref f = readCRef ref >>= writeCRef ref . f

-- | Strict version of 'modifyCRef'
--
-- @since 1.0.0.0
modifyCRef' :: MonadConc m => CRef m a -> (a -> a) -> m ()
modifyCRef' ref f = do
  x <- readCRef ref
  writeCRef ref $! f x

-- | Strict version of 'atomicModifyCRef'. This forces both the value
-- stored in the @CRef@ as well as the value returned.
--
-- @since 1.0.0.0
atomicModifyCRef' :: MonadConc m => CRef m a -> (a -> (a,b)) -> m b
atomicModifyCRef' ref f = do
  b <- atomicModifyCRef ref $ \a -> case f a of
    v@(a',_) -> a' `seq` v
  pure $! b
