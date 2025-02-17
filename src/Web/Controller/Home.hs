module Web.Controller.Home where

import Web.Scotty.Trans

import Web.Types
import qualified Web.View.Home as HomeView

index :: ActionT MatchmakerError WebM ()
index = HomeView.index
        >>= html
