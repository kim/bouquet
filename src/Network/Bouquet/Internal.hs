{-# LANGUAGE BangPatterns #-}

module Network.Bouquet.Internal
    ( measure
    ) where

import Data.Time.Clock.POSIX (getPOSIXTime)

measure :: IO a -> IO (Double, a)
measure act = do
    start  <- getTime
    result <- act
    end    <- getTime
    let !delta = end - start
    return (delta, result)

getTime :: IO Double
getTime = realToFrac `fmap` getPOSIXTime
