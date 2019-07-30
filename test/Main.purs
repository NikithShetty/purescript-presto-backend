{-
 Copyright (c) 2012-2017 "JUSPAY Technologies"
 JUSPAY Technologies Pvt. Ltd. [https://www.juspay.in]
 This file is part of JUSPAY Platform.
 JUSPAY Platform is free software: you can redistribute it and/or modify
 it for only educational purposes under the terms of the GNU Affero General
 Public License (GNU AGPL) as published by the Free Software Foundation,
 either version 3 of the License, or (at your option) any later version.
 For Enterprise/Commerical licenses, contact <info@juspay.in>.
 This program is distributed in the hope that it will be useful,
 but WITHOUT ANY WARRANTY; without even the implied warranty of
 MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  The end user will
 be liable for all damages without limitation, which is caused by the
 ABUSE of the LICENSED SOFTWARE and shall INDEMNIFY JUSPAY for such
 damages, claims, cost, including reasonable attorney fee claimed on Juspay.
 The end user has NO right to claim any indemnification based on its use
 of Licensed Software. See the GNU Affero General Public License for more details.
 You should have received a copy of the GNU Affero General Public License
 along with this program. If not, see <https://www.gnu.org/licenses/agpl.html>.
-}

module Test.Main where

import Prelude

import Cache (SimpleConn, SimpleConnOpts, db, host, newConn, port, socketKeepAlive)
import Control.Monad.Except.Trans (runExceptT)
import Control.Monad.Reader.Trans (runReaderT)
import Control.Monad.State.Trans (runStateT)
import Data.Either (Either(..))
import Data.Options ((:=), Options)
import Debug.Trace (spy)
import Effect (Effect)
import Effect.Aff (Aff, launchAff_)
import Effect.Aff.Class (liftAff)
import Effect.Class (liftEffect)
import Effect.Exception (throwException)
import Foreign.Object (Object, singleton)
import Presto.Backend.Flow (BackendFlow, log)
import Presto.Backend.Interpreter (BackendRuntime(..), Connection(..), runBackend)
import Presto.Core.Types.API (Request)

type Config = {
    test :: Boolean
}

configs = { test : true}

newtype FooState = FooState { test :: Boolean}

fooState = FooState { test : true}

apiRunner :: Request → Aff String
apiRunner r = pure "add working api runner!"

redisOptions :: Options SimpleConnOpts
redisOptions = host := "127.0.0.1"
         <> port := 6379
         <> db := 0
         <> socketKeepAlive := true

connections :: Connection -> Object Connection
connections conn = singleton "DB" conn

logRunner :: forall a. String -> a -> Aff Unit
logRunner tag value = pure (spy "tag:" tag) *> pure (spy "value:" value) *> pure unit

foo :: BackendFlow FooState Config Unit
foo = log "foo" "ran" *> pure unit

tryRedisConn :: Options SimpleConnOpts -> Aff SimpleConn
tryRedisConn opts = do
    eCacheConn <- newConn opts
    case eCacheConn of
         Right c -> pure c
         Left err -> liftEffect $ throwException err

main :: Effect Unit
main = launchAff_ start *> pure unit

start :: Aff Unit
start = do
    conn <- tryRedisConn redisOptions
    let backendRuntime = BackendRuntime apiRunner (connections (Redis conn)) logRunner
    response  <- liftAff $ runExceptT ( runStateT ( runReaderT ( runBackend backendRuntime (foo)) configs) fooState)
    pure unit