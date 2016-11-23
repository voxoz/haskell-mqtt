{-# LANGUAGE FlexibleContexts  #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE TypeFamilies      #-}
--------------------------------------------------------------------------------
-- |
-- Module      :  Network.MQTT.Authentication
-- Copyright   :  (c) Lars Petersen 2016
-- License     :  MIT
--
-- Maintainer  :  info@lars-petersen.net
-- Stability   :  experimental
--------------------------------------------------------------------------------
module Network.MQTT.Authentication where

import           Control.Exception
import qualified Data.ByteString      as BS
import qualified Data.Text            as T
import qualified Data.X509            as X509
import qualified Network.WebSockets   as WS

-- | An `Authenticator` is able to determine a `Principal`'s identity from a
--   `Request`.
class (Show (Principal a), Exception (AuthenticationException a)) => Authenticator a where
  -- | A peer identity optionally associated with connection/session
  --   specific information.
  data Principal a
  -- | This `Exception` may be thrown by any operation within this class.
  --   Operations /must/ only throw this type of exception. Other exceptions
  --   won't be catched and may kill the broker.
  data AuthenticationException a
  -- | Try to determine a `Principal`'s identity from connection `Request`.
  --
  --   The operation shall return `Nothing` in case the authentication
  --   mechanism is working, but couldn't associate an identity. It shall
  --   throw and `AuthenticationException` in case of other problems.
  authenticate :: a -> Request -> IO (Maybe (Principal a))

-- | This class defines how the information gathered from a
--   connection request looks like. An `Authenticator` may use
--   whatever information it finds suitable to authenticate the `Principal`.
data Request
   = Request
   { requestClientIdentifier :: T.Text,
     requestCleanSession     :: Bool,
     -- | The username and password supplied with the MQTT handshake.
     requestCredentials      :: Maybe (T.Text, Maybe BS.ByteString),
     -- | The HTTP request head in case the client connected via
     --   [WebSocket](https://en.wikipedia.org/wiki/WebSocket).
     requestHead             :: Maybe WS.RequestHead,
     -- | Is this connection secure in terms of
     --  [Transport Layer Security](https://en.wikipedia.org/wiki/Transport_Layer_Security)?
     requestSecure           :: Bool,
     -- | An [X.509 certificate](https://en.wikipedia.org/wiki/X.509) chain
     --   supplied by the peer.
     --   It can be assumed that the transport layer implementation already
     --   verified that the peer owns the corresponding private key. The validation
     --   of the certificate claims (including certificate chain checking) /must/
     --   be performed by the `Authenticator`.
     requestCertificateChain  :: Maybe X509.CertificateChain
   }
