{-# Language RecordWildCards          #-}
{-# OPTIONS_GHC -funbox-strict-fields #-}

-- |
-- Module      : Network.Bouquet.Base
-- Copyright   : (c) 2013 Kim Altintop <kim.altintop@gmail.com>
-- License     : This Source Code Form is subject to the terms of
--               the Mozilla Public License, v. 2.0.
--               A copy of the MPL can be found in the LICENSE file or
--               you can obtain it at http://mozilla.org/MPL/2.0/.
-- Maintainer  : Kim Altintop <kim.altintop@gmail.com>
-- Stability   : experimental
-- Portability : non-portable (GHC extensions)
--

module Network.Bouquet.Base
    ( Bouquet
    , Pool'(inUse, latencies)

    , withBouquet

    , leastUsed
    , roundRobin
    , latencyAware
    , leastAvgLatency
    , pinned
    , random
    ) where

import Control.Applicative
import Control.Exception
import Data.Function        (on)
import Data.Hashable
import Data.IORef
import Data.List
import Data.Pool
import Data.Vector          (Vector, (!))
import System.Random.MWC    (GenIO, uniformR)

import qualified Data.HashMap.Strict as H
import qualified Data.Vector         as V

import Network.Bouquet.Internal


data Pool' a = Pool'
    { inUse     :: !(IORef Int)
    , latencies :: !(IORef [Double])
    , pool      :: !(Pool a)
    }

data Pools x a = Pools
    { indexed :: !(H.HashMap x (Pool' a))
    , elems   :: Vector (Pool' a)
    }

type Choice x a = Pools x a -> IO (Pool' a)

data Bouquet x a = Bouquet
    { pools  :: Pools x a
    , choose :: Choice x a
    , sample :: Int
    }

withBouquet :: Bouquet x a -> (a -> IO b) -> IO (Maybe b)
withBouquet Bouquet{..} act = do
    Pool'{..} <- choose pools
    res       <- tryWithResource pool $ \ a -> do
        atomicModifyIORef' inUse $ \ n -> (n + 1, ())
        measure (act a) `finally`
            atomicModifyIORef' inUse (\ n -> (n - 1, ()))

    case res of
        Nothing -> return Nothing
        Just (lat, a) -> do
            atomicModifyIORef latencies $ \ ls -> (lat : take sample ls, ())
            return $ Just a


leastUsed :: Choice x a
leastUsed (Pools pools _) =
    snd . minimumBy (compare `on` fst) <$> mapM usage (H.elems pools)
  where
    usage :: Pool' a -> IO (Int, Pool' a)
    usage p@(Pool' uref _ _) = flip (,) p <$> readIORef uref


roundRobin :: IORef Int -> Choice x a
roundRobin cnt (Pools _ pools) = do
    i <- atomicModifyIORef cnt $ \ cnt' -> let next = cnt' + 1 `mod` V.length pools
                                            in (next, next)

    return (pools ! i)


latencyAware :: ([Double] -> Double) -> Choice x a
latencyAware rollup (Pools _ pools) =
    snd . V.minimumBy (compare `on` rollup . fst) <$> V.mapM lats pools
  where
    lats :: Pool' a -> IO ([Double], Pool' a)
    lats p@(Pool' _ lref _) = flip (,) p <$> readIORef lref


leastAvgLatency :: Choice x a
leastAvgLatency = latencyAware avg
  where
    avg xs = realToFrac (sum xs) / genericLength xs


pinned :: (Eq x, Hashable x) => x -> Choice x a
pinned x Pools{..} = maybe (return . V.head $ elems)
                           (return . id)
                           (H.lookup x indexed)


random :: GenIO -> Choice x a
random gen (Pools _ pools) = do
    rand <- uniformR (0, V.length pools - 1) gen
    return $ pools ! rand
