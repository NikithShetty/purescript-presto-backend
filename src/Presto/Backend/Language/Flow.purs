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

module Presto.Backend.Flow where

import Prelude

import Cache (SimpleConn)
import Cache.Multi (Multi)
import Control.Monad.Free (Free, liftF)
import Data.Either (Either(..))
import Data.Exists (Exists, mkExists)
import Data.Maybe (Maybe(..))
import Data.Options (Options)
import Data.Time.Duration (Milliseconds, Seconds)
import Effect (Effect)
import Effect.Aff (Aff, Error, error)
import Foreign (Foreign)
import Foreign.Class (class Decode, class Encode)
import Presto.Backend.DB (bCreate', create, createWithOpts, delete, findAll, findAndCountAll, findOne, update) as DB
import Presto.Core.Types.API (class RestEndpoint, Headers)
import Presto.Core.Types.Language.APIInteract (apiInteract)
import Presto.Core.Types.Language.Flow (APIResult)
import Presto.Core.Types.Language.Interaction (Interaction)
import Sequelize.Class (class Model)
import Sequelize.Types (Conn)

type LogLevel = String

data BackendException err = CustomException err | StringException Error

data BackendFlowCommands next st rt error s =
      Ask (rt -> next)
    | Get (st -> next)
    | Put st (st -> next)
    | Modify (st -> st) (st -> next)
    | CallAPI (Interaction (APIResult s)) (APIResult s -> next)
    | DoAff (Aff s) (s -> next)
    | ThrowException (BackendException error) (s -> next)
    | FindOne (Either Error (Maybe s)) (Either Error (Maybe s) -> next)
    | FindAll (Either Error (Array s)) (Either Error (Array s) -> next)
    | FindAndCountAll (Either Error {count :: Int, rows :: Array s})
        (Either Error {count :: Int, rows :: Array s} -> next)
    | Create  (Either Error (Maybe s)) (Either Error (Maybe s) -> next)
    | BulkCreate (Either Error (Array s)) (Either Error (Array s) -> next)
    | FindOrCreate (Either Error (Maybe s)) (Either Error (Maybe s) -> next)
    | Update (Either Error (Array s)) (Either Error (Array s) -> next)
    | Delete (Either Error Int) (Either Error Int -> next)
    | GetDBConn String (Conn -> next)
    | GetCacheConn String (SimpleConn -> next)
    | Log LogLevel String s next
    | SetCache SimpleConn String String (Either Error Unit -> next)
    | SetCacheWithExpiry SimpleConn String String Milliseconds (Either Error Unit -> next)
    | GetCache SimpleConn String (Either Error (Maybe String) -> next)
    | KeyExistsCache SimpleConn String (Either Error Boolean -> next)
    | DelCache SimpleConn String (Either Error Int -> next)
    | Enqueue SimpleConn String String (Either Error Unit -> next)
    | Dequeue SimpleConn String (Either Error (Maybe String) -> next)
    | GetQueueIdx SimpleConn String Int (Either Error (Maybe String) -> next)
    | Fork (BackendFlow st rt error s) (Unit -> next)
    | Expire SimpleConn String Seconds (Either Error Boolean -> next)
    | Incr SimpleConn String (Either Error Int -> next)
    | SetHash SimpleConn String String String (Either Error Boolean -> next)
    | GetHashKey SimpleConn String String (Either Error (Maybe String) -> next)
    | PublishToChannel SimpleConn String String (Either Error Int -> next)
    | Subscribe SimpleConn String (Either Error Unit -> next)
    | SetMessageHandler SimpleConn (String -> String -> Effect Unit) (Unit -> next)
    | GetMulti SimpleConn (Multi -> next)
    | SetCacheInMulti String String Multi (Multi -> next)
    | GetCacheInMulti String Multi (Multi -> next)
    | DelCacheInMulti String Multi (Multi -> next)
    | SetCacheWithExpiryInMulti String String Milliseconds Multi (Multi -> next)
    | ExpireInMulti String Seconds Multi (Multi -> next)
    | IncrInMulti String Multi (Multi -> next)
    | SetHashInMulti String String String Multi (Multi -> next)
    | GetHashInMulti String String Multi (Multi -> next)
    | PublishToChannelInMulti String String Multi (Multi -> next)
    | SubscribeInMulti String Multi (Multi -> next)
    | EnqueueInMulti String String Multi (Multi -> next)
    | DequeueInMulti String Multi (Multi -> next)
    | GetQueueIdxInMulti String Int Multi (Multi -> next)
    | Exec Multi (Either Error (Array Foreign) -> next)
    | RunSysCmd String (String -> next)
    | Attempt (BackendFlow st rt error s) ((Either (BackendException error) s) -> next)

type BackendFlowCommandsWrapper st rt error s next = BackendFlowCommands next st rt error s

newtype BackendFlowWrapper st rt error next = BackendFlowWrapper (Exists (BackendFlowCommands next st rt error))

type BackendFlow st rt error next = Free (BackendFlowWrapper st rt error) next

instance showBackendException :: Show a => Show (BackendException a) where
  show (CustomException err) = show err
  show (StringException err) = show err

wrap :: forall next st rt error s. BackendFlowCommands next st rt error s -> BackendFlow st rt error next
wrap = liftF <<< BackendFlowWrapper <<< mkExists

ask :: forall st rt error. BackendFlow st rt error rt
ask = wrap $ Ask identity

get :: forall st rt error. BackendFlow st rt error st
get = wrap $ Get identity

put :: forall st rt error. st -> BackendFlow st rt error st
put st = wrap $ Put st identity

modify :: forall st rt error. (st -> st) -> BackendFlow st rt error st
modify fst = wrap $ Modify fst identity

throwException :: forall st rt error a. String -> BackendFlow st rt error a
throwException err = wrap $ ThrowException (StringException (error err)) identity

throwCustomException :: forall st rt error a. error -> BackendFlow st rt error a
throwCustomException err = wrap $ ThrowException (CustomException err) identity

doAff :: forall st rt a error. Aff a -> BackendFlow st rt error a
doAff aff = wrap $ DoAff aff identity

findOne :: forall model st rt error. Model model => String -> Options model -> BackendFlow st rt error (Either Error (Maybe model))
findOne dbName options = do
  conn <- getDBConn dbName
  model <- doAff do
        DB.findOne conn options
  wrap $ FindOne model identity

findAll :: forall model st rt error. Model model => String -> Options model -> BackendFlow st rt error (Either Error (Array model))
findAll dbName options = do
  conn <- getDBConn dbName
  model <- doAff do
        DB.findAll conn options
  wrap $ FindAll model identity

findAndCountAll :: forall model st rt error. Model model => String -> Options model
  -> BackendFlow st rt error (Either Error {count :: Int, rows :: Array model})
findAndCountAll dbName options = do
  conn <- getDBConn dbName
  model <- doAff do
        DB.findAndCountAll conn options
  wrap $ FindAndCountAll model identity

-- query :: forall a st rt. String -> String -> BackendFlow st rt error (Either Error (Array a))
-- query dbName rawq = do
--   conn <- getDBConn dbName
--   resp <- doAff do
--         DB.query conn rawq
--   wrap $ Query resp identity

bulkCreate :: forall model st rt error. Model model => String -> Array model -> BackendFlow st rt error (Either Error (Array model))
bulkCreate dbName model = do
  conn <- getDBConn dbName
  result <- doAff do
        DB.bCreate' conn model
  wrap $ BulkCreate result identity

create :: forall model st rt error. Model model => String -> model -> BackendFlow st rt error (Either Error (Maybe model))
create dbName model = do
  conn <- getDBConn dbName
  result <- doAff do
        DB.create conn model
  wrap $ Create result identity

createWithOpts :: forall model st rt error. Model model => String -> model -> Options model -> BackendFlow st rt error (Either Error (Maybe model))
createWithOpts dbName model options = do
  conn <- getDBConn dbName
  result <- doAff do
        DB.createWithOpts conn model options
  wrap $ Create result identity

findOrCreate :: forall model st rt error. Model model => String -> Options model -> BackendFlow st rt error (Either Error (Maybe model))
findOrCreate dbName options = do
  conn <- getDBConn dbName
  wrap $ FindOrCreate (Right Nothing) identity

update :: forall model st rt error. Model model => String -> Options model -> Options model -> BackendFlow st rt error (Either Error (Array model))
update dbName updateValues whereClause = do
  conn <- getDBConn dbName
  model <- doAff do
        DB.update conn updateValues whereClause
  wrap $ Update model identity

delete :: forall model st rt error. Model model => String -> Options model -> BackendFlow st rt error (Either Error Int)
delete dbName options = do
  conn <- getDBConn dbName
  model <- doAff do
        DB.delete conn options
  wrap $ Delete model identity

getDBConn :: forall st rt error. String -> BackendFlow st rt error Conn
getDBConn dbName = do
  wrap $ GetDBConn dbName identity

getCacheConn :: forall st rt error. String -> BackendFlow st rt error SimpleConn
getCacheConn dbName = wrap $ GetCacheConn dbName identity

newMulti :: forall st rt error. String -> BackendFlow st rt error Multi
newMulti cacheName = do
    cacheConn <- getCacheConn cacheName
    wrap $ GetMulti cacheConn identity

callAPI :: forall st rt a error b. Encode a => Decode b => RestEndpoint a b
  => Headers -> a -> BackendFlow st rt error (APIResult b)
callAPI headers a = wrap $ CallAPI (apiInteract a headers) identity

setCacheInMulti :: forall st rt error. String -> String -> Multi -> BackendFlow st rt error Multi
setCacheInMulti key value multi = wrap $ SetCacheInMulti key value multi identity

setCache :: forall st rt error. String -> String ->  String -> BackendFlow st rt error (Either Error Unit)
setCache cacheName key value = do
  cacheConn <- getCacheConn cacheName
  wrap $ SetCache cacheConn key value identity

getCacheInMulti :: forall st rt error. String -> Multi -> BackendFlow st rt error Multi
getCacheInMulti key multi = wrap $ GetCacheInMulti key multi identity

getCache :: forall st rt error. String -> String -> BackendFlow st rt error (Either Error (Maybe String))
getCache cacheName key = do
  cacheConn <- getCacheConn cacheName
  wrap $ GetCache cacheConn key identity

keyExistsCache :: forall st rt error. String -> String -> BackendFlow st rt error (Either Error Boolean)
keyExistsCache cacheName key = do
  cacheConn <- getCacheConn cacheName
  wrap $ KeyExistsCache cacheConn key identity

delCacheInMulti :: forall st rt error. String -> Multi -> BackendFlow st rt error Multi
delCacheInMulti key multi = wrap $ DelCacheInMulti key multi identity

delCache :: forall st rt error. String -> String -> BackendFlow st rt error (Either Error Int)
delCache cacheName key = do
  cacheConn <- getCacheConn cacheName
  wrap $ DelCache cacheConn key identity

setCacheWithExpireInMulti :: forall st rt error. String -> String -> Milliseconds -> Multi -> BackendFlow st rt error Multi
setCacheWithExpireInMulti key value ttl multi = wrap $ SetCacheWithExpiryInMulti key value ttl multi identity

setCacheWithExpiry :: forall st rt error. String -> String -> String -> Milliseconds -> BackendFlow st rt error (Either Error Unit)
setCacheWithExpiry cacheName key value ttl = do
  cacheConn <- getCacheConn cacheName
  wrap $ SetCacheWithExpiry cacheConn key value ttl identity

log :: forall st rt error a. LogLevel -> String -> a -> BackendFlow st rt error Unit
log level tag message = wrap $ Log level tag message unit

expireInMulti :: forall st rt error. String -> Seconds -> Multi -> BackendFlow st rt error Multi
expireInMulti key ttl multi = wrap $ ExpireInMulti key ttl multi identity

expire :: forall st rt error. String -> String -> Seconds -> BackendFlow st rt error (Either Error Boolean)
expire cacheName key ttl = do
  cacheConn <- getCacheConn cacheName
  wrap $ Expire cacheConn key ttl identity

incrInMulti :: forall st rt error. String -> Multi -> BackendFlow st rt error Multi
incrInMulti key multi = wrap $ IncrInMulti key multi identity

incr :: forall st rt error. String -> String -> BackendFlow st rt error (Either Error Int)
incr cacheName key = do
  cacheConn <- getCacheConn cacheName
  wrap $ Incr cacheConn key identity

setHashInMulti :: forall st rt error. String -> String -> String -> Multi -> BackendFlow st rt error Multi
setHashInMulti key field value multi = wrap $ SetHashInMulti key field value multi identity

setHash :: forall st rt error. String -> String -> String -> String -> BackendFlow st rt error (Either Error Boolean)
setHash cacheName key field value = do
  cacheConn <- getCacheConn cacheName
  wrap $ SetHash cacheConn key field value identity

getHashKeyInMulti :: forall st rt error. String -> String -> Multi -> BackendFlow st rt error Multi
getHashKeyInMulti key field multi = wrap $ GetHashInMulti key field multi identity

getHashKey :: forall st rt error. String -> String -> String -> BackendFlow st rt error (Either Error (Maybe String))
getHashKey cacheName key field = do
  cacheConn <- getCacheConn cacheName
  wrap $ GetHashKey cacheConn key field identity

publishToChannelInMulti :: forall st rt error. String -> String -> Multi -> BackendFlow st rt error Multi
publishToChannelInMulti channel message multi = wrap $ PublishToChannelInMulti channel message multi identity

publishToChannel :: forall st rt error. String -> String -> String -> BackendFlow st rt error (Either Error Int)
publishToChannel cacheName channel message = do
  cacheConn <- getCacheConn cacheName
  wrap $ PublishToChannel cacheConn channel message identity

subscribeToMulti :: forall st rt error. String -> Multi -> BackendFlow st rt error Multi
subscribeToMulti channel multi = wrap $ SubscribeInMulti channel multi identity

subscribe :: forall st rt error. String -> String -> BackendFlow st rt error (Either Error Unit)
subscribe cacheName channel = do
  cacheConn <- getCacheConn cacheName
  wrap $ Subscribe cacheConn channel identity

enqueueInMulti :: forall st rt error. String -> String -> Multi -> BackendFlow st rt error Multi
enqueueInMulti listName value multi = wrap $ EnqueueInMulti listName value multi identity

enqueue :: forall st rt error. String -> String -> String -> BackendFlow st rt error (Either Error Unit)
enqueue cacheName listName value = do
  cacheConn <- getCacheConn cacheName
  wrap $ Enqueue cacheConn listName value identity

dequeueInMulti :: forall st rt error. String -> Multi -> BackendFlow st rt error Multi
dequeueInMulti listName multi = wrap $ DequeueInMulti listName multi identity

dequeue :: forall st rt error. String -> String -> BackendFlow st rt error (Either Error (Maybe String))
dequeue cacheName listName = do
  cacheConn <- getCacheConn cacheName
  wrap $ Dequeue cacheConn listName identity

getQueueIdxInMulti :: forall st rt error. String -> Int -> Multi -> BackendFlow st rt error Multi
getQueueIdxInMulti listName index multi = wrap $ GetQueueIdxInMulti listName index multi identity

getQueueIdx :: forall st rt error. String -> String -> Int -> BackendFlow st rt error (Either Error (Maybe String))
getQueueIdx cacheName listName index = do
  cacheConn <- getCacheConn cacheName
  wrap $ GetQueueIdx cacheConn listName index identity

execMulti :: forall st rt error. Multi -> BackendFlow st rt error (Either Error (Array Foreign))
execMulti multi = wrap $ Exec multi identity

setMessageHandler :: forall st rt error. String -> ((String -> String -> Effect Unit)) -> BackendFlow st rt error Unit
setMessageHandler cacheName f = do
  cacheConn <- getCacheConn cacheName
  wrap $ SetMessageHandler cacheConn f identity

forkFlow :: forall s st rt error. BackendFlow st rt error s -> BackendFlow st rt error Unit
forkFlow flow = wrap $ Fork flow identity

attemptFlow :: forall s st rt error. BackendFlow st rt error s -> BackendFlow st rt error (Either (BackendException error) s)
attemptFlow flow = wrap $ Attempt flow identity

runSysCmd :: forall st rt error. String -> BackendFlow st rt error String
runSysCmd cmd = wrap $ RunSysCmd cmd identity
