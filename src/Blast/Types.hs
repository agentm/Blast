{-
Copyright   : (c) Jean-Christophe Mincke, 2016-2017

This Source Code Form is subject to the terms of the Mozilla Public
License, v. 2.0. If a copy of the MPL was not distributed with this
file, You can obtain one at http://mozilla.org/MPL/2.0/.
-}

{-# LANGUAGE AllowAmbiguousTypes #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE FunctionalDependencies #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE UndecidableInstances #-}


module Blast.Types
(
  Computation
  , LocalComputation
  , RemoteComputation
  , Kind (..)
  , Partition
  , Chunkable (..)
  , UnChunkable (..)
  , ChunkableFreeVar (..)
  , ChunkFun
  , UnChunkFun
  , Fun (..)
  , FoldFun (..)
  , ExpClosure (..)
  , Indexable (..)
  , Builder (..)
  , Syntax (..)
  , GenericInfoMap
  , GenericInfo (..)
  , rapply'
  , rconst'
  , rconst
  , rconstIO
  , lconst
  , lconstIO
  , collect'
  , collect
  , lapply
  , rapply
  , refCount
  , generateReferenceMap
  , build
  , JobDesc (..)
  , Config (..)
  , defaultConfig
  , fun
  , closure
  , foldFun
  , foldClosure
  , funIO
  , closureIO
  , foldFunIO
  , foldClosureIO
  , partitionSize
  , getPart

)
where

--import Debug.Trace
import qualified  Control.Lens as Lens ()
import            Control.Monad.Operational
import qualified  Data.List as L
import qualified  Data.Map as M
import qualified  Data.Set as S
import qualified  Data.Serialize as S
import qualified  Data.Vector as Vc


data GenericInfo i = GenericInfo {
  giRefs :: S.Set Int -- set of parents, that is, nodes that reference this node
  , giInfo :: i
  }
    deriving Show

-- $(Lens.makeLenses ''GenericInfo)

type GenericInfoMap i = M.Map Int (GenericInfo i)

-- | Generic type describing a computation.
type Computation m e (k::Kind) a =
    Control.Monad.Operational.ProgramT (Syntax m) m (e k a)

-- | A computation that evaluates as a local value.
type LocalComputation a = forall e m. (Monad m, Builder m e) => Computation m e 'Local a


-- | A computation that evaluates as a remote value.
type RemoteComputation a = forall e m. (Monad m, Builder m e) => Computation m e 'Remote a

-- | Kind of computation.
data Kind = Remote | Local

-- | Represents the partitioning of a remote value.
type Partition a = Vc.Vector a

partitionSize :: Partition a -> Int
partitionSize v = Vc.length v

getPart :: Int -> Partition a -> Maybe a
getPart i p | i <= partitionSize p - 1 = Just $ p Vc.! i
getPart _ _ = Nothing

-- | Values that can be partitionned.
class Chunkable a b | a -> b, b -> a where
  -- | Given a value "a", chunk it into 'n' parts.
  chunk :: Int -> a -> Partition b

-- | Values that can be reconstructed from a list of parts.
class UnChunkable b a | b -> a, b -> a where
  -- | Given a list of parts, reconstruct a value.
  unChunk :: [b] -> a

-- | Values that can be reconstructed from a list of parts.
-- This applies to local values that are captured by a closure.
-- Helps optimize the implementation of remote relational operators or more generally, remote dyadic operators.
class ChunkableFreeVar a where
  -- | Given a list of parts, reconstruct a value.
  chunk' :: Int -> a -> Partition a
  chunk' n a = Vc.generate n (const a)


data Fun e a b =
  Pure (a -> IO b)
  |forall c . (S.Serialize c, ChunkableFreeVar c) => Closure (e 'Local c) (c -> a -> IO b)

data FoldFun e a r =
  FoldPure (r -> a -> IO r)
  |forall c . (S.Serialize c,ChunkableFreeVar c) => FoldClosure (e 'Local c) (c -> r -> a -> IO r)

data ExpClosure e a b =
  forall c . (S.Serialize c, ChunkableFreeVar c) => ExpClosure (e 'Local c) (c -> a -> IO b)


class Indexable e where
  getIndex :: e (k::Kind) a -> Int

type ChunkFun a b = Int -> a -> Partition b
type UnChunkFun b a = [b] -> a

class (Indexable e) => Builder m e where
  makeRApply :: Int -> ExpClosure e a b -> e 'Remote a -> m (e 'Remote b)
  makeRConst :: (S.Serialize b) => Int -> ChunkFun a b -> IO a -> m (e 'Remote b)
  makeLConst :: Int -> IO a -> m (e 'Local a)
  makeCollect :: (S.Serialize b) => Int -> UnChunkFun b a -> e 'Remote b -> m (e 'Local a)
  makeLApply :: Int -> e 'Local (a -> b) -> e 'Local a -> m (e 'Local b)

data Syntax m e where
  StxRApply :: (Builder m e) => ExpClosure e a b -> e 'Remote a -> Syntax m (e 'Remote b)
  StxRConst :: (Builder m e, S.Serialize b) => ChunkFun a b -> IO a -> Syntax m (e 'Remote b)
  StxLConst :: (Builder m e) => IO a -> Syntax m (e 'Local a)
  StxCollect :: (Builder m e, S.Serialize b) => UnChunkFun b a -> e 'Remote b -> Syntax m (e 'Local a)
  StxLApply :: (Builder m e) => e 'Local (a -> b) -> e 'Local a -> Syntax m (e 'Local b)

-- | Applies a ExpClosure to remote value.
rapply' :: (Builder m e)
  => ExpClosure e a b
  -> e 'Remote a
  -> Computation m e 'Remote b
rapply' f a = singleton (StxRApply f a)

-- | Creates a remote value, passing a specific chunk function.
rconst' :: (S.Serialize b) =>
  ChunkFun a b -> IO a -> RemoteComputation b
rconst' f a = singleton (StxRConst f a)

-- | Creates a remote value.
rconst :: (S.Serialize b, Chunkable a b) => a -> RemoteComputation b
rconst a = rconst' chunk (return a)

-- | Creates a remote value.
rconstIO :: (S.Serialize b, Chunkable a b) => IO a -> RemoteComputation b
rconstIO a = rconst' chunk a

-- | Creates a local value.
lconst :: a -> LocalComputation a
lconst a = singleton (StxLConst (return a))

-- | Creates a local value.
lconstIO :: IO a -> LocalComputation a
lconstIO a = singleton (StxLConst a)

-- | Creates a local value from a remote value, passing a specific chunk function.
collect' :: (S.Serialize b, Builder m e) =>
  UnChunkFun b a ->  e 'Remote b -> Computation m e 'Local a
collect' f a = singleton (StxCollect f a)

-- | Creates a local value from a remote value, passing a specific chunk function.
collect :: (S.Serialize b, Builder m e, UnChunkable b a) =>
  e 'Remote b -> Computation m e 'Local a
collect a = collect' unChunk a

-- | Applies a function to a local value.
lapply :: (Builder m e) =>
  e 'Local (a -> b) -> e 'Local a -> Computation m e 'Local b
lapply f a = singleton (StxLApply f a)


-- | Applies a closure to remote value.
rapply :: (Monad m, Builder m e) =>
        Fun e a b -> e 'Remote a -> Computation m e 'Remote b
rapply fm e  = do
  cs <- mkRemoteClosure fm
  rapply' cs e
  where
  mkRemoteClosure (Pure f) = do
    ue <- lconst ()
    return $ ExpClosure ue (\() a -> f a)
  mkRemoteClosure (Closure ce f) = return $ ExpClosure ce (\c a -> f c a)



refCount :: Int -> GenericInfoMap i -> Int
refCount n m =
  case M.lookup n m of
    Just (GenericInfo refs _) -> S.size refs
    Nothing -> error ("Ref count not found for node: " ++ show n)

addUnitInfo :: Int -> GenericInfoMap () -> GenericInfoMap ()
addUnitInfo n refMap =
  case M.lookup n refMap of
    Just _ -> error $  ("Node " ++ show n ++ " already exists")
    Nothing -> M.insert n (GenericInfo S.empty ()) refMap


reference :: Int -> Int -> GenericInfoMap i -> GenericInfoMap i
reference parent child refMap = do
  case M.lookup child refMap of
    Just inf@(GenericInfo old _) -> M.insert child (inf {giRefs = S.insert parent old}) refMap
    Nothing -> error $  ("Node " ++ show child ++ " is referenced before being visited")

generateReferenceMap ::forall a m e. (Builder m e, Monad m) =>  Int -> GenericInfoMap () -> ProgramT (Syntax m) m (e 'Local a) -> m (GenericInfoMap (), Int)
generateReferenceMap counter refMap p = do
    pv <- viewT p
    eval pv
    where
    eval :: (Builder m e, Monad m) => ProgramViewT (Syntax m) m (e 'Local a) -> m (GenericInfoMap(), Int)
    eval (StxRApply cs@(ExpClosure ce _) a :>>=  is) = do
      e <- makeRApply counter cs a
      let refMap' = addUnitInfo counter refMap
      let refMap'' = reference counter (getIndex ce) refMap'
      let refMap''' = reference counter (getIndex a) refMap''
      generateReferenceMap (counter+1) refMap''' (is e)
    eval (StxRConst f a :>>=  is) = do
      e <- makeRConst counter f a
      let refMap' = addUnitInfo counter refMap
      generateReferenceMap (counter+1) refMap' (is e)
    eval (StxLConst a :>>=  is) = do
      e <- makeLConst counter a
      let refMap' = addUnitInfo counter refMap
      generateReferenceMap (counter+1) refMap' (is e)
    eval (StxCollect f a :>>=  is) = do
      e <- makeCollect counter f a
      let refMap' = addUnitInfo counter refMap
      let refMap'' = reference counter (getIndex a) refMap'
      generateReferenceMap (counter+1) refMap'' (is e)
    eval (StxLApply f a :>>=  is) = do
      e <- makeLApply counter f a
      let refMap' = addUnitInfo counter refMap
      let refMap'' = reference counter (getIndex f) refMap'
      let refMap''' = reference counter (getIndex a) refMap''
      generateReferenceMap (counter+1) refMap''' (is e)
    eval (Return _) = return (refMap, counter)



build ::forall a m e. (Builder m e, Monad m) => GenericInfoMap () -> Int -> ProgramT (Syntax m) m (e 'Local a)  -> m (e 'Local a)
build refMap counter p = do
    pv <- viewT p
    eval pv
    where
    eval :: (Builder m e, Monad m) => ProgramViewT (Syntax m) m (e 'Local a) -> m (e 'Local a)
    eval (StxRApply cs@(ExpClosure _ _) a :>>=  is) = do
      e <- makeRApply counter cs a
      build refMap (counter+1) (is e)
    eval (StxRConst chunkFun a :>>=  is) = do
      e <- makeRConst counter chunkFun a
      build refMap (counter+1) (is e)
    eval (StxLConst a :>>=  is) = do
      e <- makeLConst counter a
      build refMap (counter+1) (is e)
    eval (StxCollect f a :>>=  is) = do
      e <- makeCollect counter f a
      build refMap (counter+1) (is e)
    eval (StxLApply f a :>>=  is) = do
      e <- makeLApply counter f a
      build refMap (counter+1) (is e)
    eval (Return a) = return a


-- | Definition of a recursive job.
data JobDesc a b = MkJobDesc {
    -- | The initial value passed to the computation generator.
    seed :: a
  -- | The computation generator.
  , computationGen :: a -> (forall e m. (Monad m, Builder m e) => Computation m e 'Local (a, b))
  -- | An action that is executed after each iteration.
  , reportingAction :: a -> b -> IO a
  -- | Predicate that determines whether or not to continue the computation (False to continue, True to exit)
  , shouldStop  :: a -> a -> b -> Bool
  }


data Config = MkConfig
  {
    slaveAvailability :: Float    -- ^ Probability of slave failure. Used in testing.
    , statefullSlaves :: Bool       -- ^ True turns on the statefull slave mode. Slaves are stateless if False.
  }

-- | Default configuration
-- @
-- defaultConfig = MkConfig False 1.0 True
-- @
defaultConfig :: Config
defaultConfig = MkConfig 1.0 True

-- instances

instance {-# OVERLAPPABLE #-} ChunkableFreeVar a
instance {-# OVERLAPPABLE #-} (ChunkableFreeVar a , ChunkableFreeVar b) => ChunkableFreeVar (a,b) where
  chunk' n (a, c) =
    Vc.zip pb pd
    where
    pb = chunk' n a
    pd = chunk' n c

instance ChunkableFreeVar ()


instance {-# OVERLAPPABLE #-} Chunkable [a] [a] where
  chunk nbBuckets l =
    Vc.reverse $ Vc.fromList $ go [] nbBuckets l
    where
    go acc 1 ls = ls:acc
    go acc n ls = go (L.take nbPerBucket ls : acc) (n-1) (L.drop nbPerBucket ls)
    len = L.length l
    nbPerBucket = len `div` nbBuckets

instance {-# OVERLAPPABLE #-} UnChunkable [a] [a] where
  unChunk l = L.concat l



-- | Creates a closure from a pure function.
fun :: (a -> b) -> Fun e a b
fun f = Pure (return . f)

-- | Creates a closure from a pure function and a local value.
closure :: (S.Serialize c, ChunkableFreeVar c) => e 'Local c -> (c -> a -> b) -> Fun e a b
closure ce f = Closure ce (\c a -> return $ f c a)


-- | Creates a folding closure from a pure function.
foldFun :: (r -> a -> r) -> FoldFun e a r
foldFun f = FoldPure (\r a -> return $ f r a)

-- | Creates a folding closure from a pure function and a local value.
foldClosure :: (S.Serialize c, ChunkableFreeVar c) => e 'Local c -> (c -> r -> a -> r) -> FoldFun e a r
foldClosure ce f = FoldClosure ce (\c r a -> return $ f c r a)

-- | Creates a closure from a impure function.
funIO :: (a -> IO b) -> Fun k a b
funIO f = Pure f

-- | Creates a closure from a impure function and a local value.
closureIO :: (S.Serialize c, ChunkableFreeVar c) => e 'Local c -> (c -> a -> IO b) -> Fun e a b
closureIO ce f = Closure ce f

-- | Creates a folding closure from a impure function.
foldFunIO :: (r -> a -> IO r) -> FoldFun e a r
foldFunIO f = FoldPure f

-- | Creates a folding closure from a impure function and a local value.
foldClosureIO :: (S.Serialize c, ChunkableFreeVar c) => e 'Local c -> (c -> r -> a -> IO r) -> FoldFun e a r
foldClosureIO ce f = FoldClosure ce f

