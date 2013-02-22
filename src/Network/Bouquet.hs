{-# LANGUAGE BangPatterns               #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE LambdaCase                 #-}
{-# LANGUAGE RecordWildCards            #-}

{-# OPTIONS_GHC -fno-warn-orphans       #-}

module Network.Bouquet
    ( Bouquet
    , BouquetConf

    -- * monadic
    , runBouquet
    , retry

    -- * running actions
    , async
    , latencyAware
    , pinned

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
    } deriving (Applicative, Functor, Monad, MonadIO, MonadCatchIO, MonadPlus)

instance Alternative Bouquet where
    empty = Bouquet $! mzero
    (<|>) = mplus

data BouquetConf = BouquetConf {
      addrs :: [(HostName, PortID)]
    }

-- | Run the 'Bouquet' monad
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

-- | Run the 'Bouquet' monad asynchronously. 'wait' from the async package can
-- be used to block on the result.
async :: Bouquet a -> Bouquet (Async a)
async b = Bouquet $ do
    e <- ask
    liftIO $ do
        atomicModifyIORef (_refcount e) $ \ n -> (succ n, ())
        Async.async $ runReaderT (unBouquet b) e `E.finally` destroy e

-- | Run the action by trying to acquire a connection from the given host pool.
--
-- The function returns immediately if no connection from the given host pool
-- can be acquired. The latency of the action is sampled, so that it affects
-- subsequent use of 'latencyAware'.
pinned :: HostId -> (Socket -> IO a) -> Bouquet (Maybe a)
pinned host act = Bouquet $ do
    pools  <- asks _pools
    scores <- asks _scores

    maybe (return Nothing)
          (\ pool -> do
              res <- liftIO $ tryWithResource pool (measure . act)
              case res of
                  Nothing -> return Nothing
                  Just (lat,a) -> do
                      !_ <- liftIO $ sample host lat scores
                      return (Just a))
          (H.lookup host pools)

-- | Run the action by trying to acquire a connection from the least-latency
-- host pool.
--
-- Note that the function returns immediately with 'Nothing' if no connection
-- can be acquired.  You may want to use 'retrying' to increase the chance of
-- getting a connection to another host.
--
-- Also note that exceptions thrown from the action are not handled.
latencyAware :: (Socket -> IO a) -> Bouquet (Maybe a)
latencyAware act = Bouquet $ do
    pools  <- asks _pools
    whRef  <- asks _weightedHosts
    scores <- asks _scores

    host <- liftIO $ head <$> readIORef whRef
    let pool = pools H.! host

    res <- liftIO $ tryWithResource pool (measure . act)
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
    scores' :: (HostId, IORef [Double]) -> IO (HostId, Double)
    scores' (k, vref) = do
        v <- readIORef vref
        let avg = sum v / fromIntegral (length v)
         in return (k, avg)


-- | Repeatedly run the 'Bouquet' monad up to N times if an exception occurs.
--
-- If after N attempts we still don't have a result value, we return the last
-- exception in a 'Left'. Note that subsequent attempts are subject to
-- expontential backoff, using 'threadDelay' to sleep in between attempts. Thus,
-- you may want to run this within 'async'.
--
-- Warning: using 'retry' is never a sane default. Since we handle all
-- exceptions uniformly, it is impossible to tell whether it is safe to retry.
retry :: Exception e => Bouquet a -> Int -> Bouquet (Either e a)
retry b max_attempts = Bouquet $ ask >>= liftIO . go 0
  where
    go attempt e = do
          _ <- liftIO $ threadDelay (backoff attempt * 1000)
          catch (Right <$> runReaderT (unBouquet b) e)
                (\ ex -> if attempt == max_attempts
                           then return (Left ex)
                           else go (attempt + 1) e)

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
