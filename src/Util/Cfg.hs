{-
 - Copyright 2015 Per Magnus Therning
 -
 - Licensed under the Apache License, Version 2.0 (the "License");
 - you may not use this file except in compliance with the License.
 - You may obtain a copy of the License at
 -
 -     http://www.apache.org/licenses/LICENSE-2.0
 -
 - Unless required by applicable law or agreed to in writing, software
 - distributed under the License is distributed on an "AS IS" BASIS,
 - WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 - See the License for the specific language governing permissions and
 - limitations under the License.
 -}

module Util.Cfg
    where

data Cfg = Cfg { cfgIdxUrl :: String }
    deriving (Show)

readCfg :: FilePath -> IO Cfg
readCfg = const (return $ Cfg "http://hackage.fpcomplete.com/00-index.tar.gz")

getIndexFileName :: Cfg -> String
getIndexFileName cfg = map repSlash $ drop 7 $ cfgIdxUrl cfg
    where
        repSlash c = if c == '/' then '_' else c