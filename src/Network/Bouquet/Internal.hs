{-# LANGUAGE BangPatterns #-}

-- |
-- Module      : Network.Bouquet.Internal
-- Copyright   : (c) 2013 Kim Altintop <kim.altintop@gmail.com>
-- License     : This Source Code Form is subject to the terms of
--               the Mozilla Public License, v. 2.0.
--               A copy of the MPL can be found in the LICENSE file or
--               you can obtain it at http://mozilla.org/MPL/2.0/.
-- Maintainer  : Kim Altintop <kim.altintop@gmail.com>
-- Stability   : experimental
-- Portability : non-portable (GHC extensions)
--

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
