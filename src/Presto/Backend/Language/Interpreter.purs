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

module Presto.Backend.Interpreter where

import Prelude

import Cache (SetOptions(..), SimpleConn, del, exists, expire, get, incr, publish, set, setMessageHandler, subscribe)
import Cache.Hash (hget, hset)
import Cache.List (lindex, lpop, rpush)
import Cache.Multi (execMulti, expireMulti, getMulti, hgetMulti, hsetMulti, incrMulti, lindexMulti, lpopMulti, newMulti, publishMulti, rpushMulti, setMulti, subscribeMulti)
import Control.Monad.Except.Trans (ExceptT(..), lift, throwError, runExceptT) as E
import Control.Monad.Free (foldFree)
import Control.Monad.Reader.Trans (ReaderT, ask, lift, runReaderT) as R
import Control.Monad.State.Trans (StateT, get, lift, modify, put, runStateT) as S
import Data.Array.NonEmpty (singleton) as NEArray
import Data.Either (Either(..))
import Data.Exists (runExists)
import Data.Maybe (Maybe(..))
import Data.Tuple (Tuple(..))
import Effect.Aff (Aff, error, forkAff)
import Effect.Aff.Class (liftAff)
import Effect.Class (liftEffect)
import Foreign.Object (Object, lookup)
import Presto.Backend.Flow (BackendException(..), BackendFlow, BackendFlowCommands(..), BackendFlowCommandsWrapper, BackendFlowWrapper(..), LogLevel)
import Presto.Backend.SystemCommands (runSysCmd)
import Presto.Core.Language.Runtime.API (APIRunner, runAPIInteraction)
import Sequelize.Types (Conn)

type InterpreterMT rt st err a = R.ReaderT rt (S.StateT st (E.ExceptT err (Aff))) a

type Cache = {
    name :: String
  , connection :: SimpleConn
}

type DB = {
    name :: String
  , connection :: Conn
}

type LogRunner = forall a. LogLevel -> String -> a -> Aff Unit

data Connection = Sequelize Conn | Redis SimpleConn

data BackendRuntime = BackendRuntime APIRunner (Object Connection) LogRunner


interpret :: forall st rt s a err.  BackendRuntime -> BackendFlowCommandsWrapper st rt err s a -> InterpreterMT rt st (BackendException err) a
interpret _ (Ask next) = R.ask >>= (pure <<< next)

interpret _ (Get next) = R.lift (S.get) >>= (pure <<< next)

interpret _ (Put d next) = R.lift (S.put d) *> (pure <<< next) d

interpret _ (Modify d next) = R.lift (S.modify d) *> S.get >>= (pure <<< next)

interpret _ (ThrowException err next) = (R.lift $ S.lift $ E.ExceptT $ Left <$> (pure $ err)) >>= pure <<< next

interpret _ (DoAff aff nextF) = (R.lift $ S.lift $ E.lift aff) >>= (pure <<< nextF)

interpret _ (SetCache cacheConn key value next) = (R.lift $ S.lift $ E.lift $ void <$> set cacheConn key value Nothing NoOptions) >>= (pure <<< next)

interpret _ (SetCacheWithExpiry cacheConn key value ttl next) = (R.lift $ S.lift $ E.lift $ void <$> set cacheConn key value (Just ttl) NoOptions) >>= (pure <<< next)

interpret _ (GetCache cacheConn key next) = (R.lift $ S.lift $ E.lift $ get cacheConn key) >>= (pure <<< next)

interpret _ (KeyExistsCache cacheConn key next) = (R.lift $ S.lift $ E.lift $ exists cacheConn key) >>= (pure <<< next)

interpret _ (DelCache cacheConn key next) = (R.lift $ S.lift $ E.lift $ del cacheConn (NEArray.singleton key)) >>= (pure <<< next)

interpret _ (Expire cacheConn key ttl next) = (R.lift $ S.lift $ E.lift $ expire cacheConn key ttl) >>= (pure <<< next)

interpret _ (Incr cacheConn key next) = (R.lift $ S.lift $ E.lift $ incr cacheConn key) >>= (pure <<< next)

interpret _ (SetHash cacheConn key field value next) = (R.lift $ S.lift $ E.lift $ hset cacheConn key field value) >>= (pure <<< next)

interpret _ (GetHashKey cacheConn key field next) = (R.lift $ S.lift $ E.lift $ hget cacheConn key field) >>= (pure <<< next)

interpret _ (PublishToChannel cacheConn channel message next) = (R.lift $ S.lift $ E.lift $ publish cacheConn channel message) >>= (pure <<< next)

interpret _ (Subscribe cacheConn channel next) = (R.lift $ S.lift $ E.lift $ subscribe cacheConn (NEArray.singleton channel)) >>= (pure <<< next)

interpret _ (SetMessageHandler cacheConn f next) = (R.lift $ S.lift $ E.lift $ liftEffect $ setMessageHandler cacheConn f) >>= (pure <<< next)

interpret _ (Enqueue cacheConn listName value next) = (R.lift $ S.lift $ E.lift $ void <$> rpush cacheConn listName value) >>= (pure <<< next)

interpret _ (Dequeue cacheConn listName next) = (R.lift $ S.lift $ E.lift $ lpop cacheConn listName) >>= (pure <<< next)

interpret _ (GetQueueIdx cacheConn listName index next) = (R.lift $ S.lift $ E.lift $ lindex cacheConn listName index) >>= (pure <<< next)

interpret _ (GetMulti cacheConn next) = (R.lift $ S.lift $ E.lift $ liftEffect $ newMulti cacheConn) >>= (pure <<< next)

interpret _ (SetCacheInMulti key val multi next) = (R.lift <<< S.lift <<< E.lift <<< liftEffect <<< setMulti key val Nothing NoOptions $ multi ) >>= (pure <<< next)

interpret _ (GetCacheInMulti key multi next) = (R.lift <<< S.lift <<< E.lift <<< pure <<< next $ multi)

interpret _ (DelCacheInMulti key multi next) = (R.lift <<< S.lift <<< E.lift <<< liftEffect <<< getMulti key $ multi) >>= (pure <<< next )

interpret _ (SetCacheWithExpiryInMulti key val ttl multi next) = (R.lift <<< S.lift <<< E.lift <<< liftEffect <<< setMulti key val (Just ttl) NoOptions $ multi )>>= (pure <<< next )

interpret _ (ExpireInMulti key ttl multi next) = (R.lift <<< S.lift <<< E.lift <<< liftEffect <<< expireMulti key ttl $ multi) >>= (pure <<< next)

interpret _ (IncrInMulti key multi next) = (R.lift <<< S.lift <<< E.lift <<< liftEffect <<< incrMulti key $ multi) >>= (pure <<< next)

interpret _ (SetHashInMulti key field value multi next) = (R.lift <<< S.lift <<< E.lift <<< liftEffect <<< hsetMulti key field value $ multi) >>= (pure <<< next )

interpret _ (GetHashInMulti key value multi next) = (R.lift <<< S.lift <<< E.lift <<< liftEffect <<< hgetMulti key value $ multi) >>= (pure <<< next )

interpret _ (PublishToChannelInMulti channel message multi next) = (R.lift <<< S.lift <<< E.lift <<< liftEffect <<< publishMulti channel message $ multi) >>= (pure <<< next)

interpret _ (SubscribeInMulti channel multi next) = (R.lift <<< S.lift <<< E.lift <<< liftEffect <<< subscribeMulti channel $ multi) >>= (pure <<< next)

interpret _ (EnqueueInMulti listName val multi next) = (R.lift <<< S.lift <<< E.lift <<< liftEffect <<< rpushMulti listName val $ multi) >>= (pure <<< next)

interpret _ (DequeueInMulti listName multi next) = (R.lift <<< S.lift <<< E.lift <<< liftEffect <<< lpopMulti listName $ multi) >>= (pure <<< next)

interpret _ (GetQueueIdxInMulti listName index multi next) = (R.lift <<< S.lift <<< E.lift <<< liftEffect <<< lindexMulti listName index $ multi) >>= (pure <<< next)

interpret _ (Exec multi next) = (R.lift <<< S.lift <<< E.lift <<< execMulti $ multi) >>= (pure <<< next)

interpret (BackendRuntime a connections c) (GetCacheConn cacheName next) = do
  maybeCache <- pure $ lookup cacheName connections
  case maybeCache of
    Just (Redis cache) -> (pure <<< next) cache
    Just _ -> interpret (BackendRuntime a connections c) (ThrowException (StringException $ error "No Cache found") next)
    Nothing -> interpret (BackendRuntime a connections c) (ThrowException (StringException $ error "No Cache found") next)

interpret _ (FindOne model next) = (pure <<< next) model

interpret _ (FindAll models next) = (pure <<< next) models

interpret _ (FindAndCountAll models next) = (pure <<< next) models

interpret _ (BulkCreate model next) = (pure <<< next) model

-- interpret _ (Query models next) = (pure <<< next) models

interpret _ (Create model next) = (pure <<< next) model

interpret _ (Update model next) = (pure <<< next) model

interpret _ (Delete model next) = (pure <<< next) model

interpret ((BackendRuntime a connections c)) (GetDBConn dbName next) = do
  maybedb <- pure $ lookup dbName connections
  case maybedb of
    Just (Sequelize db) -> (pure <<< next) db
    Just _ -> interpret (BackendRuntime a connections c) (ThrowException (StringException $ error "No DB Found") next)
    Nothing -> interpret (BackendRuntime a connections c) (ThrowException (StringException $ error "No DB Found") next)


interpret (BackendRuntime apiRunner _ _) (CallAPI apiInteractionF nextF) = do
  R.lift $ S.lift $ E.lift $ runAPIInteraction apiRunner apiInteractionF
    >>= (pure <<< nextF)

interpret (BackendRuntime _ _ logRunner) (Log level tag message next) = (R.lift ( S.lift ( E.lift (logRunner level tag message)))) *> pure next

interpret r (Fork flow nextF) = do
  st <- R.lift $ S.get
  rt <- R.ask
  let m = E.runExceptT ( S.runStateT ( R.runReaderT ( runBackend r flow ) rt) st)
  R.lift $ S.lift $ E.lift $ forkAff m *> (pure <<< nextF) unit

interpret r (Attempt flow nextF) = do
  st <- R.lift $ S.get
  rt <- R.ask
  let m = E.runExceptT ( S.runStateT ( R.runReaderT ( runBackend r flow ) rt) st)
  result <- R.lift $ S.lift $ E.lift $ liftAff m
  (pure <<< nextF) $ do
      case result of
        Right (Tuple x _) ->  Right x
        Left b -> Left b

interpret _ (RunSysCmd cmd next) = R.lift $ S.lift $ E.lift $ runSysCmd cmd >>= (pure <<< next)

interpret _ _ = E.throwError $ StringException $ error "Not implemented yet!"

runBackend :: forall st rt err a. BackendRuntime -> BackendFlow st rt err a -> InterpreterMT rt st (BackendException err) a
runBackend backendRuntime = foldFree (\(BackendFlowWrapper x) -> runExists (interpret backendRuntime) x)
