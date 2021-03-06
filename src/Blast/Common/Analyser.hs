{-
Copyright   : (c) Jean-Christophe Mincke, 2016-2017

This Source Code Form is subject to the terms of the Mozilla Public
License, v. 2.0. If a copy of the MPL was not distributed with this
file, You can obtain one at http://mozilla.org/MPL/2.0/.
-}


{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE TemplateHaskell #-}

module Blast.Common.Analyser
(
  CachedValType (..)
  , RemoteClosureResult (..)
  , RemoteClosureImpl
  , Data (..)
  , referenceM
  , wasVisitedM
)
where

--import Debug.Trace

import            Control.DeepSeq
import            Control.Monad.Logger
import            Control.Monad.Trans.State
import            Data.Binary (Binary)
import qualified  Data.Map as M
import qualified  Data.Set as S
import qualified  Data.Text as T
import qualified  Data.Vault.Strict as V
import            GHC.Generics (Generic)

import            Blast.Types


data CachedValType = CachedArg | CachedFreeVar
  deriving (Show, Generic)

data RemoteClosureResult =
  RcRespCacheMiss CachedValType
  |RcRespOk
  |RcRespError String
  deriving (Generic, Show)


instance NFData RemoteClosureResult
instance NFData CachedValType

instance Binary RemoteClosureResult
instance Binary CachedValType

type RemoteClosureImpl = V.Vault -> IO (RemoteClosureResult, V.Vault)


data Data a =
  Data a
  |NoData
  deriving (Show, Generic)

instance (Binary a) => Binary (Data a)
instance (NFData a) => NFData (Data a)

referenceM :: forall i m. MonadLoggerIO m =>
                Int -> Int -> StateT (GenericInfoMap i) m ()
referenceM parent child = do
  $(logInfo) $ T.pack ("Parent node "++show parent ++ " references child node " ++ show child)
  m <- get
  put (doReference m)
  where
  doReference m =
    case M.lookup child m of
    Just inf@(GenericInfo old _) -> M.insert child (inf {giRefs = S.insert parent old}) m
    Nothing -> error $  ("Node " ++ show child ++ " is referenced before being visited")



wasVisitedM ::  forall i m. Monad m =>
                Int -> StateT (GenericInfoMap i) m Bool
wasVisitedM n = do
  m <- get
  return $ M.member n m



