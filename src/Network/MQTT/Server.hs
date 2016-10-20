{-# LANGUAGE OverloadedStrings #-}
--------------------------------------------------------------------------------
-- |
-- Module      :  Network.MQTT
-- Copyright   :  (c) Lars Petersen 2016
-- License     :  MIT
--
-- Maintainer  :  info@lars-petersen.net
-- Stability   :  experimental
--------------------------------------------------------------------------------
module Network.MQTT.Server where

import Data.Monoid
import Data.Int
import Data.Typeable
import qualified Data.Map as M
import qualified Data.IntSet as S
import qualified Data.IntMap as IM
import qualified Data.ByteString as BS
import qualified Data.ByteString.Builder as BS
import qualified Data.ByteString.Lazy as LBS
import qualified Data.Text as T

import Control.Exception
import Control.Monad
import Control.Concurrent
import Control.Concurrent.MVar
import Control.Concurrent.Async

import System.Random

import Network.MQTT.SubscriptionTree

type SessionKey = Int
type Message = ()

newtype Server  = Server  { unServer  :: MVar ServerState }
newtype Session = Session { unSession :: MVar SessionState }

data ServerState
  =  ServerState
    { serverMaxSessionKey           :: !SessionKey
    , serverSubscriptions           :: !SubscriptionTree
    , serverSessions                :: !(IM.IntMap Session)
    }

data SessionState
  =  SessionState
    { sessionServer                 :: !Server
    , sessionKey                    :: !SessionKey
    , sessionSubscriptions          :: !SubscriptionTree
    }

newSession :: Server -> IO Session
newSession (Server server) = modifyMVar server $ \serverState-> do
  let newSessionKey    = serverMaxSessionKey serverState + 1
  newSession <- Session <$> newMVar SessionState
       { sessionServer        = Server server
       , sessionKey           = newSessionKey
       , sessionSubscriptions = mempty
       }
  let newServerState = serverState
       { serverMaxSessionKey  = newSessionKey
       , serverSessions       = IM.insert newSessionKey newSession (serverSessions serverState)
       }
  pure (newServerState, newSession)

closeSession :: Session -> IO ()
closeSession (Session session) =
  withMVar session $ \sessionState->
    modifyMVar_ (unServer $ sessionServer sessionState) $ \serverState->
      pure $ serverState
        { serverSubscriptions = difference (serverSubscriptions serverState)
                                           (sessionSubscriptions sessionState)
        , serverSessions      = IM.delete  (sessionKey sessionState)
                                           (serverSessions serverState)
        }

subscribeSession :: Session -> [Filter] -> IO ()
subscribeSession (Session session) filters =
  modifyMVar_ session $ \sessionState->
    modifyMVar (unServer $ sessionServer sessionState) $ \serverState-> do
      let newSubscriptions = foldl (flip $ subscribe $ sessionKey sessionState) mempty filters
      let newSessionState = sessionState
           { sessionSubscriptions = newSubscriptions <> sessionSubscriptions sessionState
           }
      let newServerState = serverState
           { serverSubscriptions = newSubscriptions <> serverSubscriptions serverState
           }
      pure (newServerState, newSessionState)

deliverSession  :: Session -> Topic -> Message -> IO ()
deliverSession = undefined

publishServer   :: Server -> Topic -> Message -> IO ()
publishServer (Server server) topic message = do
  serverState <- readMVar server
  forM_ (S.elems $ subscribers topic $ serverSubscriptions serverState) $ \key->
    case IM.lookup (key :: Int) (serverSessions serverState) of
      Nothing      -> pure ()
      Just session -> deliverSession session topic message

{-
type  SessionKey = Int

data  MqttServerSessions
   =  MqttServerSessions
      { maxSession    :: SessionKey
      , subscriptions :: SubscriptionTree
      , session       :: IM.IntMap MqttServerSession
      }


data  MqttServerSession
    = MqttServerSession
      { sessionServer                  :: MqttServer
      , sessionConnection              :: MVar (Async ())
      , sessionOutputBuffer            :: MVar RawMessage
      , sessionBestEffortQueue         :: BC.BoundedChan Message
      , sessionGuaranteedDeliveryQueue :: BC.BoundedChan Message
      , sessionInboundPacketState      :: MVar (IM.IntMap InboundPacketState)
      , sessionOutboundPacketState     :: MVar (IM.IntMap OutboundPacketState)
      , sessionSubscriptions           :: S.Set TopicFilter
      }

data  Identity
data  InboundPacketState

data  OutboundPacketState
   =  NotAcknowledgedPublishQoS1 Message
   |  NotReceivedPublishQoS2     Message
   |  NotCompletePublishQoS2     Message

data MConnection
   = MConnection
     { msend    :: Message -> IO ()
     , mreceive :: IO Message
     , mclose   :: IO ()
     }

publish :: MqttServerSession -> Message -> IO ()
publish session message = case qos message of
  -- For QoS0 messages, the queue will simply overflow and messages will get
  -- lost. This is the desired behaviour and allowed by contract.
  QoS0 ->
    void $ BC.writeChan (sessionBestEffortQueue session) message
  -- For QoS1 and QoS2 messages, an overflow will kill the connection and
  -- delete the session. We cannot otherwise signal the client that we are
  -- unable to further serve the contract.
  _ -> do
    success <- BC.tryWriteChan (sessionGuaranteedDeliveryQueue session) message
    unless success undefined -- sessionTerminate session

dispatchConnection :: MqttServer -> Connection -> IO ()
dispatchConnection server connection =
  withConnect $ \clientIdentifier cleanSession keepAlive mwill muser j-> do
    -- Client sent a valid CONNECT packet. Next, authenticate the client.
    midentity <- serverAuthenticate server muser
    case midentity of
      -- Client authentication failed. Send CONNACK with `NotAuthorized`.
      Nothing -> send $ ConnectAcknowledgement $ Left NotAuthorized
      -- Cient authenticaion successfull.
      Just identity -> do
        -- Retrieve session; create new one if necessary.
        (session, sessionPresent) <- getSession server clientIdentifier
        -- Now knowing the session state, we can send the success CONNACK.
        send $ ConnectAcknowledgement $ Right sessionPresent
        -- Replace (and shutdown) existing connections.
        modifyMVar_ (sessionConnection session) $ \previousConnection-> do
          cancel previousConnection
          async $ maintainConnection session `finally` close connection
  where
    -- Tries to receive the first packet and (if applicable) extracts the
    -- CONNECT information to call the contination with.
    withConnect :: (ClientIdentifier -> CleanSession -> KeepAlive -> Maybe Will -> Maybe (Username, Maybe Password) -> BS.ByteString -> IO ()) -> IO ()
    withConnect  = undefined

    send :: RawMessage -> IO ()
    send  = undefined

    maintainConnection :: MqttServerSession -> IO ()
    maintainConnection session =
      processKeepAlive `race_` processInput `race_` processOutput
        `race_` processBestEffortQueue `race_` processGuaranteedDeliveryQueue

      where
        processKeepAlive = undefined
        processInput     = undefined
        processOutput    = undefined
        processBestEffortQueue = forever $ do
          message <- BC.readChan (sessionBestEffortQueue session)
          putMVar (sessionOutputBuffer session) Publish
            { publishDuplicate = False
            , publishRetain    = retained message
            , publishQoS       = undefined -- Nothing
            , publishTopic     = topic message
            , publishBody      = payload message
            }
        processGuaranteedDeliveryQueue = undefined

getSession :: MqttServer -> ClientIdentifier -> IO (MqttServerSession, SessionPresent)
getSession server clientIdentifier =
  modifyMVar (serverSessions server) $ \ms->
    case M.lookup clientIdentifier ms of
      Just session -> pure (ms, (session, True))
      Nothing      -> do
        mthread <- newMVar =<< async (pure ())
        session <- MqttServerSession
          <$> pure server
          <*> pure mthread
          <*> newEmptyMVar
          <*> BC.newBoundedChan 1000
          <*> BC.newBoundedChan 1000
          <*> newEmptyMVar
          <*> newEmptyMVar
        pure (M.insert clientIdentifier session ms, (session, False))
-}
