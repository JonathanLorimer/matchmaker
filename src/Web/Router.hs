{-# OPTIONS_GHC -Wno-unused-imports #-}
module Web.Router where

import Prelude hiding (get)

import Network.Wai.Middleware.Auth
import Network.Wai.Middleware.Cors (simpleCors)
import Network.Wai.Middleware.RequestLogger (logStdoutDev)
import Network.Wai.Middleware.Static
import Web.Scotty.Trans (ScottyT, defaultHandler, get, middleware, post)

import qualified Web.Controller.Home as Home
import qualified Web.Controller.Session as Session
import qualified Web.Controller.Account as Account
import Web.Types
import Web.Helpers
import Web.Templates (errorHandler)

router :: HasCallStack => ScottyT MatchmakerError WebM ()
router = do
  middleware logStdoutDev
  middleware $ staticPolicy noDots
  middleware simpleCors
  defaultHandler errorHandler

  get "/"              Home.index
  get "/login"         Session.new
  post "/login/signin" Session.create

  get "/signup" Account.new
  post "/account/create" Account.create
