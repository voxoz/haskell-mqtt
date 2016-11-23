{-# LANGUAGE FlexibleContexts   #-}
{-# LANGUAGE FlexibleInstances  #-}
{-# LANGUAGE OverloadedStrings  #-}
{-# LANGUAGE StandaloneDeriving #-}
{-# LANGUAGE TypeFamilies       #-}
--------------------------------------------------------------------------------
-- |
-- Module      :  Network.Stack.Server
-- Copyright   :  (c) Lars Petersen 2016
-- License     :  MIT
--
-- Maintainer  :  info@lars-petersen.net
-- Stability   :  experimental
--------------------------------------------------------------------------------
module Network.Stack.Server where

import           Control.Concurrent.Async
import           Control.Concurrent.MVar
import qualified Control.Exception             as E
import           Control.Monad
import qualified Data.ByteString               as BS
import qualified Data.ByteString.Builder       as BS
import qualified Data.ByteString.Builder.Extra as BS
import qualified Data.ByteString.Lazy          as BSL
import           Data.Int
import           Data.Typeable
import qualified Data.X509                     as X509
import           Foreign.Storable
import qualified Network.TLS                   as TLS
import qualified Network.WebSockets            as WS
import qualified Network.WebSockets.Stream     as WS
import qualified System.Socket                 as S
import qualified System.Socket.Type.Stream     as S

data TLS a
data WebSocket a

class (Typeable a) => ServerStack a where
  --type ServerMessage a
  data Server a
  data ServerConfig a
  data ServerException a
  data ServerConnection a
  data ServerConnectionInfo a
  -- | Creates a new server from a configuration and passes it to a handler function.
  --
  --   The server given to the handler function shall be bound and in
  --   listening state. The handler function is usually a
  --   `Control.Monad.forever` loop that accepts and handles new connections.
  --
  --   > withServer config $ \server->
  --   >   forever $ withConnection handleConnection
  withServer     :: ServerConfig a -> (Server a -> IO b) -> IO b
  -- | Waits for and accepts a new connection from a listening server and passes
  --   it to a handler function.
  --
  --   This operation is blocking until the lowest layer in the stack accepts
  --   a new connection. The handlers of all other layers are executed within
  --   an `Control.Concurrent.Async.Async` which is returned. This allows
  --   the main thread waiting on the underlying socket to block just as long
  --   as necessary. Upper layer protocol handshakes (TLS etc) will be executed
  --   in the new thread.
  --
  --   > withServer config $ \server-> forever $
  --   >   future <- withConnection server handleConnection
  --   >   putStrLn "The lowest layer accepted a new connection!"
  --   >   async $ do
  --   >       result <- wait future
  --   >       putStrLn "The connection handler returned:"
  --   >       print result
  withConnection :: Server a -> (ServerConnection a -> ServerConnectionInfo a -> IO b) -> IO (Async b)

class ServerStack a => StreamServerStack a where
  sendStream              :: ServerConnection a -> BS.ByteString -> IO Int
  sendStream server bs     = fromIntegral <$> sendStreamLazy server (BSL.fromStrict bs)
  sendStreamLazy          :: ServerConnection a -> BSL.ByteString -> IO Int64
  sendStreamLazy server    = foldM
    (\sent bs-> sendStream server bs >>= \sent'-> pure $! sent + fromIntegral sent') 0 . BSL.toChunks
  sendStreamBuilder       :: ServerConnection a -> Int -> BS.Builder -> IO Int64
  sendStreamBuilder server chunksize = sendStreamLazy server
    . BS.toLazyByteStringWith (BS.untrimmedStrategy chunksize chunksize) mempty
  receiveStream           :: ServerConnection a -> IO BS.ByteString
  receiveStream server     = BSL.toStrict <$> receiveStreamLazy server
  receiveStreamLazy       :: ServerConnection a -> IO BSL.ByteString
  receiveStreamLazy server = BSL.fromStrict <$> receiveStream server
  {-# MINIMAL (sendStream|sendStreamLazy), (receiveStream|receiveStreamLazy) #-}

class ServerStack a => MessageServerStack a where
  type ClientMessage a
  type ServerMessage a
  sendMessage      :: ServerConnection a -> ServerMessage a -> IO Int64
  sendMessages     :: Foldable t => ServerConnection a -> t (ServerMessage a) -> IO Int64
  receiveMessage   :: ServerConnection a -> IO (ClientMessage a)
  consumeMessages  :: ServerConnection a -> (ClientMessage a -> IO Bool) -> IO ()

instance (Typeable f, Typeable p, Storable (S.SocketAddress f), S.Family f, S.Protocol p) => StreamServerStack (S.Socket f S.Stream p) where
  sendStream (SocketServerConnection s) bs = S.sendAll s bs S.msgNoSignal
  sendStreamLazy (SocketServerConnection s) lbs = S.sendAllLazy s lbs S.msgNoSignal
  sendStreamBuilder (SocketServerConnection s) bufsize builder = S.sendAllBuilder s bufsize builder S.msgNoSignal
  receiveStream (SocketServerConnection s) = S.receive s 4096 S.msgNoSignal

instance (StreamServerStack a) => StreamServerStack (TLS a) where
  sendStreamLazy connection lbs = TLS.sendData (tlsContext connection) lbs >> pure (BSL.length lbs)
  receiveStream     connection  = TLS.recvData (tlsContext connection)

instance (StreamServerStack a) => StreamServerStack (WebSocket a) where
  sendStream     connection bs  = WS.sendBinaryData (wsConnection connection) bs  >> pure (BS.length bs)
  sendStreamLazy connection lbs = WS.sendBinaryData (wsConnection connection) lbs >> pure (BSL.length lbs)
  receiveStreamLazy connection  = WS.receiveData    (wsConnection connection)

deriving instance Show (S.SocketAddress f) => Show (ServerConnectionInfo (S.Socket f t p))
deriving instance Show (ServerConnectionInfo a) => Show (ServerConnectionInfo (TLS a))
deriving instance Show (ServerConnectionInfo a) => Show (ServerConnectionInfo (WebSocket a))

instance (S.Family f, S.Type t, S.Protocol p, Typeable f, Typeable t, Typeable p) => ServerStack (S.Socket f t p) where
  data Server (S.Socket f t p) = SocketServer
    { socketServer       :: !(S.Socket f t p)
    , socketServerConfig :: !(ServerConfig (S.Socket f t p))
    }
  data ServerConfig (S.Socket f t p) = SocketServerConfig
    { socketServerConfigBindAddress :: !(S.SocketAddress f)
    , socketServerConfigListenQueueSize :: Int
    }
  data ServerException (S.Socket f t p) = SocketServerException !S.SocketException
  data ServerConnection (S.Socket f t p) = SocketServerConnection !(S.Socket f t p)
  data ServerConnectionInfo (S.Socket f t p) = SocketServerConnectionInfo !(S.SocketAddress f)
  withServer c handle = E.bracket
    (SocketServer <$> S.socket <*> pure c)
    (S.close . socketServer) $ \server-> do
      S.setSocketOption (socketServer server) (S.ReuseAddress True)
      S.bind (socketServer server) (socketServerConfigBindAddress $ socketServerConfig server)
      S.listen (socketServer server) (socketServerConfigListenQueueSize $ socketServerConfig server)
      handle server
  withConnection server handle =
    E.bracketOnError (S.accept (socketServer server)) (S.close . fst) $ \(connection, addr)->
      async (handle (SocketServerConnection connection) (SocketServerConnectionInfo addr) `E.finally` S.close connection)

instance (StreamServerStack a) => ServerStack (TLS a) where
  --type ServerMessage (TLS a) = BS.ByteString
  data Server (TLS a) = TlsServer
    { tlsTransportServer            :: Server a
    , tlsServerConfig               :: ServerConfig (TLS a)
    }
  data ServerConfig (TLS a) = TlsServerConfig
    { tlsTransportConfig            :: ServerConfig a
    , tlsServerParams               :: TLS.ServerParams
    }
  data ServerException (TLS a) = TlsServerException
  data ServerConnection (TLS a) = TlsServerConnection
    { tlsTransportConnection        :: ServerConnection a
    , tlsContext                    :: TLS.Context
    }
  data ServerConnectionInfo (TLS a) = TlsServerConnectionInfo
    { tlsTransportServerConnectionInfo :: ServerConnectionInfo a
    , tlsCertificateChain              :: Maybe X509.CertificateChain
    }
  withServer config handle =
    withServer (tlsTransportConfig config) $ \server->
      handle (TlsServer server config)
  withConnection server handle =
    withConnection (tlsTransportServer server) $ \connection info-> do
      let backend = TLS.Backend {
          TLS.backendFlush = pure ()
        , TLS.backendClose = pure () -- backend gets closed automatically
        , TLS.backendSend  = void . sendStream connection
        , TLS.backendRecv  = const (receiveStream connection)
        }
      mvar <- newEmptyMVar
      context <- TLS.contextNew backend (tlsServerParams $ tlsServerConfig server)
      TLS.contextHookSetCertificateRecv context (putMVar mvar)
      TLS.handshake context
      certificateChain <- tryTakeMVar mvar
      x <- handle
        (TlsServerConnection connection context)
        (TlsServerConnectionInfo info certificateChain)
      TLS.bye context
      pure x

instance (StreamServerStack a) => ServerStack (WebSocket a) where
  --type ServerMessage (WebSocket a) = BS.ByteString
  data Server (WebSocket a) = WebSocketServer
    { wsTransportServer            :: Server a
    }
  data ServerConfig (WebSocket a) = WebSocketServerConfig
    { wsTransportConfig            :: ServerConfig a
    }
  data ServerException (WebSocket a) = WebSocketServerException
  data ServerConnection (WebSocket a) = WebSocketServerConnection
    { wsTransportConnection           :: ServerConnection a
    , wsConnection                    :: WS.Connection
    }
  data ServerConnectionInfo (WebSocket a) = WebSocketServerConnectionInfo
    { wsTransportServerConnectionInfo :: ServerConnectionInfo a
    , wsRequestHead                   :: WS.RequestHead
    }
  withServer config handle =
    withServer (wsTransportConfig config) $ \server->
      handle (WebSocketServer server)
  withConnection server handle =
    withConnection (wsTransportServer server) $ \connection info-> do
      let readSocket = (\bs-> if BS.null bs then Nothing else Just bs) <$> receiveStream connection
      let writeSocket Nothing   = pure ()
          writeSocket (Just bs) = void (sendStream connection (BSL.toStrict bs))
      stream <- WS.makeStream readSocket writeSocket
      pendingConnection <- WS.makePendingConnectionFromStream stream (WS.ConnectionOptions $ pure ())
      acceptedConnection <- WS.acceptRequestWith pendingConnection (WS.AcceptRequest $ Just "mqtt")
      x <- handle
        (WebSocketServerConnection connection acceptedConnection)
        (WebSocketServerConnectionInfo info $ WS.pendingRequest pendingConnection)
      WS.sendClose acceptedConnection ("Thank you for flying Haskell." :: BS.ByteString)
      pure x
