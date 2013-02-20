{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE LambdaCase                 #-}
{-# LANGUAGE RecordWildCards            #-}

{-# OPTIONS_GHC -fno-warn-orphans       #-}

module Network.Bouquet
    ( Bouquet
    , BouquetConf

    , async
    , runBouquet
    , withSocket

    -- * retrying
    , retry

    -- * re-exports
    , Async
    ) where

import           Control.Applicative
import           Control.Concurrent         (threadDelay)
import           Control.Concurrent.Async   (Async)
import           Control.Monad
import           Control.Monad.CatchIO
import           Control.Monad.IO.Class
import           Control.Monad.Trans.Reader
import           Data.Bits                  (shiftL)
import           Data.Hashable
import           Data.HashMap.Strict        (HashMap)
import           Data.IORef
import           Data.List                  (sortBy)
import           Data.Ord                   (comparing)
import           Data.Pool
import           Data.Word
import           Network                    (HostName, PortID (..), Socket)

import qualified Control.Concurrent.Async   as Async
import qualified Control.Exception          as E
import qualified Data.HashMap.Strict        as H

import           Network.Bouquet.Internal


type HostId = (HostName,PortID)

data BouquetEnv = Env {
      _pools         :: !(HashMap HostId (Pool Socket))
    , _weightedHosts :: !(IORef [HostId])
    , _scores        :: !(HashMap HostId (IORef [Double]))
    , _refcount      :: !(IORef Word)
    }

instance Hashable PortID where
    hashWithSalt salt port = hashWithSalt salt (show port)

newtype Bouquet a = Bouquet {
      unBouquet :: ReaderT BouquetEnv IO a
    } deriving (Functor, Applicative, Monad, MonadIO, MonadCatchIO)

data BouquetConf = BouquetConf {
      addrs :: [(HostName, PortID)]
    }

runBouquet :: MonadIO m => BouquetConf -> Bouquet a -> m a
runBouquet BouquetConf{..} b = liftIO $
    bracket setup destroy (runReaderT (unBouquet b))
  where
    setup = do
        pools  <- H.fromList . zip addrs <$> mapM createPool' addrs
        scores <- H.fromList . zip addrs <$> mapM newIORef []
        weighs <- newIORef addrs
        refcnt <- newIORef 1

        return $ Env pools weighs scores refcnt

    createPool' addr = createPool (connectSock addr) disconnectSock 1 1 1

async :: Bouquet a -> Bouquet (Async a)
async b = Bouquet $ do
    e <- ask
    liftIO $ do
        atomicModifyIORef (_refcount e) $ \ n -> (succ n, ())
        Async.async $
            (runReaderT (unBouquet b) e) `E.finally` destroy e

withSocket :: (Socket -> IO a) -> Bouquet (Maybe a)
withSocket f = Bouquet $ do
    pools  <- asks _pools
    whRef  <- asks _weightedHosts
    scores <- asks _scores

    host <- liftIO $ head <$> readIORef whRef
    let pool = pools H.! host

    res <- liftIO $ tryWithResource pool (measure . f) `onException` return Nothing
    case res of
        Nothing -> return Nothing
        Just (lat,a) -> do
            liftIO $ do
                reshuffle <- sample host lat scores
                when reshuffle $ do
                    xs <- map fst . sortBy (comparing snd) <$>
                          mapM scores' (H.toList scores)
                    atomicWriteIORef whRef xs

            return $ Just a

  where
    scores' :: (HostId, IORef [Double])-> IO (HostId, Double)
    scores' (k, vref) = do
        v <- readIORef vref
        let avg = sum v / fromIntegral (length v)
         in return (k, avg)

retry :: (Socket -> IO b) -> Int -> Bouquet (Maybe b)
retry act max_attempts = go 0
  where
    go attempt
      | attempt == max_attempts = return Nothing
      | otherwise = do
          _ <- liftIO $ threadDelay (backoff attempt * 1000)
          r <- withSocket act `onException` return Nothing
          case r of
              y @ (Just _) -> return y
              Nothing      -> go (attempt + 1)

    backoff attempt = 1 `shiftL` (attempt - 1)

--
-- Internal
--

-- | Sample a latency value for the given host. Returns 'True' if the sample
-- window is full.
sample :: HostId -> Double -> HashMap HostId (IORef [Double]) -> IO Bool
sample host score m =
    maybe (return False)
          (\ ref -> atomicModifyIORef ref $ \ scores ->
              let full    = length scores >= sampleWindow
                  scores' = score : if full then [] else scores
               in (scores', full))
          (H.lookup host m)

sampleWindow :: Int
sampleWindow = 100


destroy :: BouquetEnv -> IO ()
destroy env = do
    atomicModifyIORef' (_refcount env) $ \ n -> (pred n, ())
    -- todo: can't do much except letting GC kick in
    return ()
