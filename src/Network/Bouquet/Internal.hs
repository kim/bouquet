{-# LANGUAGE BangPatterns #-}

module Network.Bouquet.Internal
    ( connectSock
    , disconnectSock
    , measure
    ) where

import Control.Exception     (IOException, bracketOnError, catch, throwIO)
import Data.Time.Clock.POSIX (getPOSIXTime)
import Network               (PortID (..))
import Network.BSD           (getProtocolNumber)
import Network.Socket


measure :: IO a -> IO (Double, a)
measure act = do
    start  <- getTime
    result <- act
    end    <- getTime
    let !delta = end - start
    return (delta, result)

getTime :: IO Double
getTime = realToFrac `fmap` getPOSIXTime

disconnectSock :: Socket -> IO ()
disconnectSock = sClose

connectSock :: (HostName, PortID) -> IO Socket
connectSock (h, (Service s))       = connect' h s
connectSock (h, (PortNumber p))    = connect' h (show p)
connectSock (_, (UnixSocket path)) =
    bracketOnError
        (socket AF_UNIX Stream 0)
        (sClose)
        (\ sock -> do
            connect sock (SockAddrUnix path)
            return sock)

connect' :: HostName -> ServiceName -> IO Socket
connect' host srv = do
    proto <- getProtocolNumber "tcp"
    let hints = defaultHints { addrFlags      = [AI_ADDRCONFIG]
                             , addrProtocol   = proto
                             , addrSocketType = Stream
                             }
    addrs <- getAddrInfo (Just hints) (Just host) (Just srv)
    firstSuccessful $ map tryToConnect addrs

  where
    tryToConnect addr =
        bracketOnError
            (socket (addrFamily addr)
                    (addrSocketType addr)
                    (addrProtocol addr))
            (sClose)
            (\ sock -> do
                connect sock (addrAddress addr)
                return sock)


catchIO :: IO a -> (IOException -> IO a) -> IO a
catchIO = catch

firstSuccessful :: [IO a] -> IO a
firstSuccessful [] = error "firstSuccessful: empty list"
firstSuccessful (p:ps) = catchIO p $ \ e ->
    case ps of
        [] -> throwIO e
        _  -> firstSuccessful ps
