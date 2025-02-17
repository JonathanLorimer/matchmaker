{-# LANGUAGE OverloadedStrings   #-}
{-# LANGUAGE ScopedTypeVariables #-}
module Web.Sessions
  ( -- * Data-types
    ScottySM
  , UserAssigns(..)
    -- * High-level API
  , putAssign
  , popAssign
  , fetchAssign
  , getSession
    -- * Helper
  , createSessionManager
  ) where

import Control.Arrow (first)
import Control.Concurrent (forkIO, threadDelay)
import Control.Concurrent.STM (atomically)
import Crypto.Random.Types (getRandomBytes)
import qualified Data.ByteString.Base64 as B64
import qualified Data.HashMap.Strict as HM
import Data.List (lookup)
import qualified Data.Text as T
import Data.Time.Clock (NominalDiffTime, addUTCTime, getCurrentTime)
import Data.Time.Format (defaultTimeLocale, formatTime)
import Network.Wai (Request (requestHeaders))
import Prelude hiding (atomically, first)
import Web.Scotty.Trans (ActionT, ScottyError, request, setHeader)

import Web.Types

putAssign :: Text -> Text -> ActionT MatchmakerError WebM ()
putAssign key value = do
  sm <- asks sessions
  modifySession sm (\mVal -> mVal >>= Just . insertAssign key value)

popAssign :: Text -> ActionT MatchmakerError WebM (Maybe Text)
popAssign key = do
  sm <- asks sessions
  mUserAssigns <- readSession sm
  case mUserAssigns of
    Nothing -> pure Nothing
    Just ua -> do
      let content = getAssign key ua
      modifySession sm (\mVal -> mVal >>= Just . removeAssign key)
      pure content

fetchAssign :: Text -> ActionT MatchmakerError WebM (Maybe Text)
fetchAssign key = do
  sm <- asks sessions
  mUserAssigns <- readSession sm
  case mUserAssigns of
    Nothing -> pure Nothing
    Just ua -> pure $ getAssign key ua

getSession :: ActionT MatchmakerError WebM (Maybe UserAssigns)
getSession = asks sessions >>= readSession

getAssign :: Text -> UserAssigns -> Maybe Text
getAssign key (UserAssigns hm) = HM.lookup key hm

insertAssign :: Text        -- ^ Key
             -> Text        -- ^ Value
             -> UserAssigns -- ^ User assigns
             -> UserAssigns
insertAssign key value (UserAssigns hm) = UserAssigns $ HM.insert key value hm

removeAssign :: Text -- ^ Key
             -> UserAssigns -- ^ User assigns
             -> UserAssigns -- ^ New user assigns
removeAssign k (UserAssigns hm) = UserAssigns $ HM.delete k hm

-- | Create a new session manager
createSessionManager :: IO (ScottySM a)
createSessionManager = do
  storage <- newTVarIO HM.empty
  forkIO $ maintainSessions storage
  pure $ ScottySM storage

-- | Modify the current users session
modifySession :: (MonadIO m, ScottyError e)
              => ScottySM UserAssigns
              -- ^ The session manager
              -> (Maybe UserAssigns -> Maybe UserAssigns)
              -- ^ The function to apply
              -> ActionT e m ()
modifySession sm@(ScottySM storage) fun = do
  oldS <- readSession' sm id
  let newS = oldS {sess_content = fun (sess_content oldS)}
  liftIO $ insertSession newS storage

-- | Read the current users session or create one if it does not exists.
readSession :: (MonadIO m, ScottyError e)
            => ScottySM UserAssigns -> ActionT e m (Maybe UserAssigns)
readSession sm = readSession' sm sess_content

readSession' :: (MonadIO m, ScottyError e)
             => ScottySM UserAssigns
             -> (Session UserAssigns -> b)
             -> ActionT e m b
readSession' (ScottySM storage) fun = do
  mSession <- loadSession storage
  case mSession of
    Just s -> pure $ fun s
    Nothing -> do
      newS <- liftIO createSession
      liftIO $ insertSession newS storage
      setCookie newS
      pure $ fun newS

sessionTTL :: NominalDiffTime
sessionTTL = 36000 -- in seconds

-- Typed as the Int-alias `ByteLength` if using crypto-api modules
sessionIdEntropy :: Int
sessionIdEntropy = 12

createSession :: IO (Session UserAssigns)
createSession = do
  sid <- decodeUtf8 . B64.encode <$> getRandomBytes sessionIdEntropy
  now <- getCurrentTime
  let validUntil = addUTCTime sessionTTL now
  pure $ Session sid validUntil (Just $ UserAssigns HM.empty)

insertSession :: Session a -> SessionJar a -> IO ()
insertSession sess sessions =
  atomically $ modifyTVar' sessions $ \m -> HM.insert (sess_id sess) sess m

getSessionFromJar :: T.Text -> SessionJar a -> IO (Maybe (Session a))
getSessionFromJar sessId sessions = do
  s <- readTVarIO sessions
  pure $ HM.lookup sessId s

maintainSessions :: SessionJar a -> IO ()
maintainSessions sessions = do
  now <- getCurrentTime
  let stillValid sess = sess_validUntil sess > now
  atomically $ modifyTVar' sessions $ \m -> HM.filter stillValid m
  threadDelay 1000000
  maintainSessions sessions

-- | easoncxz's changes: mark cookie as HTTP-only
--
-- To be marked also `Secure` when I get some local development setup going with TLS
--
-- Advice taken from:
--    - https://www.freecodecamp.org/news/session-hijacking-and-how-to-stop-it-711e3683d1ac/
setCookie :: (Monad m) => Session a -> ActionT e m ()
setCookie sess = do
  let formattedExp =
        toLText $
        formatTime defaultTimeLocale "%a, %d %b %Y %X %Z" (sess_validUntil sess)
  setHeader "Set-Cookie" $
    "sid=" <>
    toLazy (sess_id sess) <>
    "; Path=/; Expires=" <>
    formattedExp <> "; HttpOnly; Secure; SameSite=Strict"

loadSession ::
     (MonadIO m, ScottyError e)
  => SessionJar a
  -> ActionT e m (Maybe (Session a))
loadSession sessions = do
  req <- request
  liftIO $ getUserSession req sessions

getUserSession :: Request -> SessionJar a -> IO (Maybe (Session a))
getUserSession req sessions =
  case lookupResult of
    Just sid -> lookupSession sid
    Nothing  -> pure Nothing
  where
    lookupSession sid = getSessionFromJar sid sessions
    lookupResult = lookup "cookie" (requestHeaders req)
                   >>= lookup "sid" . parseCookies . decodeUtf8

parseCookies :: T.Text -> [(T.Text, T.Text)]
parseCookies = map parseCookie . T.splitOn ";" . T.concat . words
  where
    parseCookie = first T.init . T.breakOnEnd "="
