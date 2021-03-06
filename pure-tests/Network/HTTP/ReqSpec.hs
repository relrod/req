--
-- Tests for ‘req’ package. This test suite tests correctness of constructed
-- requests.
--
-- Copyright © 2016 Mark Karpov <markkarpov@openmailbox.org>
--
-- Redistribution and use in source and binary forms, with or without
-- modification, are permitted provided that the following conditions are
-- met:
--
-- * Redistributions of source code must retain the above copyright notice,
--   this list of conditions and the following disclaimer.
--
-- * Redistributions in binary form must reproduce the above copyright
--   notice, this list of conditions and the following disclaimer in the
--   documentation and/or other materials provided with the distribution.
--
-- * Neither the name Mark Karpov nor the names of contributors may be used
--   to endorse or promote products derived from this software without
--   specific prior written permission.
--
-- THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS “AS IS” AND ANY
-- EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
-- WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
-- DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDERS BE LIABLE FOR ANY
-- DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
-- DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS
-- OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION)
-- HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT,
-- STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN
-- ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE
-- POSSIBILITY OF SUCH DAMAGE.

{-# LANGUAGE CPP                  #-}
{-# LANGUAGE DataKinds            #-}
{-# LANGUAGE DeriveGeneric        #-}
{-# LANGUAGE FlexibleInstances    #-}
{-# LANGUAGE OverloadedStrings    #-}
{-# LANGUAGE RankNTypes           #-}
{-# LANGUAGE RecordWildCards      #-}
{-# LANGUAGE ScopedTypeVariables  #-}
{-# OPTIONS_GHC -fno-warn-orphans #-}

#if __GLASGOW_HASKELL__ <  710
{-# LANGUAGE ConstraintKinds      #-}
#endif

module Network.HTTP.ReqSpec
  ( spec )
where

import Control.Exception (throwIO)
import Control.Monad.Reader
import Data.Aeson (ToJSON (..))
import Data.ByteString (ByteString)
import Data.Maybe (isNothing, fromJust)
import Data.Monoid ((<>))
import Data.Proxy
import Data.Text (Text)
import Data.Time
import GHC.Generics
import Network.HTTP.Req
import Test.Hspec
import Test.Hspec.Core.Spec (SpecM)
import Test.QuickCheck
import qualified Blaze.ByteString.Builder as BB
import qualified Data.Aeson               as A
import qualified Data.ByteString          as B
import qualified Data.ByteString.Char8    as B8
import qualified Data.ByteString.Lazy     as BL
import qualified Data.CaseInsensitive     as CI
import qualified Data.Text                as T
import qualified Data.Text.Encoding       as T
import qualified Network.HTTP.Client      as L
import qualified Network.HTTP.Types       as Y

#if !MIN_VERSION_base(4,8,0)
import Control.Applicative
import Data.Foldable (foldMap)
import Data.Monoid (mempty)
#endif

spec :: Spec
spec = do

  describe "config" $
    it "getHttpConfig has effect on resulting request" $
      property $ \config -> do
        request <- runReaderT (req_ GET url NoReqBody mempty) config
        L.proxy         request `shouldBe` httpConfigProxy         config
        L.redirectCount request `shouldBe` httpConfigRedirectCount config

  describe "methods" $ do
    let mnth
          :: forall method.
             ( HttpMethod method
             , HttpBodyAllowed (AllowsBody method) 'NoBody )
          => method
          -> SpecM () ()
        mnth method = do
          let name = httpMethodName (Proxy :: Proxy method)
          describe (B8.unpack name) $
            it "affects name of HTTP method" $ do
              request <- req_ method url NoReqBody mempty
              L.method request `shouldBe` name
    mnth GET
    mnth POST
    mnth HEAD
    mnth PUT
    mnth DELETE
    mnth TRACE
    mnth CONNECT
    mnth OPTIONS
    mnth PATCH

  describe "urls" $ do
    describe "http" $
      it "sets all the params correctly" $
        property $ \host -> do
          request <- req_ GET (http host) NoReqBody mempty
          L.secure request `shouldBe` False
          L.port   request `shouldBe` 80
          L.host   request `shouldBe` urlEncode host
    describe "https" $
      it "sets all the params correctly" $
        property $ \host -> do
          request <- req_ GET (https host) NoReqBody mempty
          L.secure request `shouldBe` True
          L.port   request `shouldBe` 443
          L.host   request `shouldBe` urlEncode host
    describe "(/~)" $
      it "attaches a path piece that is URL-encoded" $
        property $ \host pieces -> do
          let url' = foldl (/~) (https host) pieces
          request <- req_ GET url' NoReqBody mempty
          L.host request `shouldBe` urlEncode host
          L.path request `shouldBe` encodePathPieces pieces
    describe "(/:)" $
      it "attaches a path piece that is URL-encoded" $
        property $ \host pieces -> do
          let url' = foldl (/:) (https host) pieces
          request <- req_ GET url' NoReqBody mempty
          L.host request `shouldBe` urlEncode host
          L.path request `shouldBe` encodePathPieces pieces
    describe "parseUrlHttp" $ do
      it "does not recognize non-http schemes" $
        parseUrlHttp "https://httpbin.org" `shouldSatisfy` isNothing
      it "parses correct URLs" $
        property $ \host pieces queryParams ->
          not (T.null host) && wellFormed queryParams ==> do
          let (url', path, queryString) =
                assembleUrl Http host pieces queryParams
              (url'', options) = fromJust (parseUrlHttp url')
          request <- req_ GET url'' NoReqBody options
          L.host        request `shouldBe` urlEncode host
          L.path        request `shouldBe` path
          L.queryString request `shouldBe` queryString
    describe "parseUrlHttps" $ do
      it "does not recognize non-https schemes" $
        parseUrlHttps "http://httpbin.org" `shouldSatisfy` isNothing
      it "parses correct URLs" $
        property $ \host pieces queryParams ->
          not (T.null host) && wellFormed queryParams ==> do
          let (url', path, queryString) =
                assembleUrl Https host pieces queryParams
              (url'', options) = fromJust (parseUrlHttps url')
          request <- req_ GET url'' NoReqBody options
          L.host        request `shouldBe` urlEncode host
          L.path        request `shouldBe` path
          L.queryString request `shouldBe` queryString

  describe "bodies" $ do
    describe "NoReqBody" $
      it "sets body to empty byte string" $ do
        request <- req_ POST url NoReqBody mempty
        case L.requestBody request of
          L.RequestBodyBS x -> x `shouldBe` B.empty
          _ -> expectationFailure "Wrong request body constructor."
    describe "ReqBodyJson" $
      it "sets body to correct lazy byte string" $
        property $ \thing -> do
          request <- req_ POST url (ReqBodyJson thing) mempty
          case L.requestBody request of
            L.RequestBodyLBS x -> x `shouldBe` A.encode (thing :: Thing)
            _ -> expectationFailure "Wrong request body constructor."
    describe "ReqBodyBs" $
      it "sets body to specified strict byte string" $
        property $ \bs -> do
          request <- req_ POST url (ReqBodyBs bs) mempty
          case L.requestBody request of
            L.RequestBodyBS x -> x `shouldBe` bs
            _ -> expectationFailure "Wrong request body constructor."
    describe "ReqBodyLbs" $
     it "sets body to specified lazy byte string" $
        property $ \lbs -> do
          request <- req_ POST url (ReqBodyLbs lbs) mempty
          case L.requestBody request of
            L.RequestBodyLBS x -> x `shouldBe` lbs
            _ -> expectationFailure "Wrong request body constructor."
    describe "ReqBodyUrlEnc" $
      it "sets body to correct lazy byte string" $
        property $ \params -> do
          request <- req_ POST url (ReqBodyUrlEnc (formUrlEnc params)) mempty
          case L.requestBody request of
            L.RequestBodyLBS x -> x `shouldBe` renderQuery params
            _ -> expectationFailure "Wrong request body constructor."

  describe "optional parameters" $ do
    describe "header" $ do
      it "sets specified header value" $
        property $ \name value -> do
          request <- req_ GET url NoReqBody (header name value)
          lookup (CI.mk name) (L.requestHeaders request) `shouldBe` pure value
      it "left header wins" $
        property $ \name value0 value1 -> do
          request <- req_ GET url NoReqBody
            (header name value0 <> header name value1)
          lookup (CI.mk name) (L.requestHeaders request) `shouldBe` pure value0
      it "overwrites headers set by other parts of the lib" $
        property $ \value -> do
          request <- req_ POST url (ReqBodyUrlEnc mempty)
            (header "Content-Type" value)
          lookup "Content-Type" (L.requestHeaders request) `shouldBe` pure value
    describe "cookieJar" $
      it "cookie jar is set without modifications" $
        property $ \cjar -> do
          request <- req_ GET url NoReqBody (cookieJar cjar)
          L.cookieJar request `shouldBe` pure cjar
    describe "basicAuth" $ do
      it "sets Authorization header to correct value" $
        property $ \username password -> do
          request <- req_ GET url NoReqBody (basicAuth username password)
          lookup "Authorization" (L.requestHeaders request) `shouldBe`
            pure (basicAuthHeader username password)
      it "overwrites manual setting of header" $
        property $ \username password value -> do
          request0 <- req_ GET url NoReqBody
            (basicAuth username password <> header "Authorization" value)
          request1 <- req_ GET url NoReqBody
            (header "Authorization" value <> basicAuth username password)
          let result = basicAuthHeader username password
          lookup "Authorization" (L.requestHeaders request0) `shouldBe`
            pure result
          lookup "Authorization" (L.requestHeaders request1) `shouldBe`
            pure result
      it "left auth option wins" $
        property $ \username0 password0 username1 password1 -> do
          request <- req_ GET url NoReqBody
            (basicAuth username0 password0 <> basicAuth username1 password1)
          lookup "Authorization" (L.requestHeaders request) `shouldBe`
            pure (basicAuthHeader username0 password0)
    describe "oAuth2Bearer" $ do
      it "sets Authorization header to correct value" $
        property $ \token -> do
          request <- req_ GET url NoReqBody (oAuth2Bearer token)
          lookup "Authorization" (L.requestHeaders request) `shouldBe`
            pure ("Bearer " <> token)
      it "overwrites manual setting of header" $
        property $ \token value -> do
          request0 <- req_ GET url NoReqBody
            (oAuth2Bearer token <> header "Authorization" value)
          request1 <- req_ GET url NoReqBody
            (header "Authorization" value <> oAuth2Bearer token)
          let result = "Bearer " <> token
          lookup "Authorization" (L.requestHeaders request0) `shouldBe`
            pure result
          lookup "Authorization" (L.requestHeaders request1) `shouldBe`
            pure result
      it "left auth option wins" $
        property $ \token0 token1 -> do
          request <- req_ GET url NoReqBody
            (oAuth2Bearer token0 <> oAuth2Bearer token1)
          lookup "Authorization" (L.requestHeaders request) `shouldBe`
            pure ("Bearer " <> token0)
    describe "oAuth2Token" $ do
      it "sets Authorization header to correct value" $
        property $ \token -> do
          request <- req_ GET url NoReqBody (oAuth2Token token)
          lookup "Authorization" (L.requestHeaders request) `shouldBe`
            pure ("token " <> token)
      it "overwrites manual setting of header" $
        property $ \token value -> do
          request0 <- req_ GET url NoReqBody
            (oAuth2Token token <> header "Authorization" value)
          request1 <- req_ GET url NoReqBody
            (header "Authorization" value <> oAuth2Token token)
          let result = "token " <> token
          lookup "Authorization" (L.requestHeaders request0) `shouldBe`
            pure result
          lookup "Authorization" (L.requestHeaders request1) `shouldBe`
            pure result
      it "left auth option wins" $
        property $ \token0 token1 -> do
          request <- req_ GET url NoReqBody
            (oAuth2Token token0 <> oAuth2Token token1)
          lookup "Authorization" (L.requestHeaders request) `shouldBe`
            pure ("token " <> token0)
    describe "port" $
      it "sets port overwriting the defaults" $
        property $ \n -> do
          request <- req_ GET url NoReqBody (port n)
          L.port request `shouldBe` n
    describe "decompress" $
      it "sets decompress function overwriting the defaults" $
        property $ \token -> do
          request <- req_ GET url NoReqBody (decompress (/= token))
          L.decompress request token `shouldBe` False
    -- FIXME Can't really test responseTimeout right new because the
    -- ResponseTimeout data type does not implement Eq and its constructors
    -- are also not exported. Sent a PR.
    describe "httpVersion" $
      it "sets HTTP version overwriting the defaults" $
        property $ \major minor -> do
          request <- req_ GET url NoReqBody (httpVersion major minor)
          L.requestVersion request `shouldBe` Y.HttpVersion major minor

----------------------------------------------------------------------------
-- Instances

instance MonadHttp IO where
  handleHttpException = throwIO

instance MonadHttp (ReaderT HttpConfig IO) where
  handleHttpException = liftIO . throwIO
  getHttpConfig       = ask

instance Arbitrary HttpConfig where
  arbitrary = do
    httpConfigProxy         <- arbitrary
    httpConfigRedirectCount <- arbitrary
    let httpConfigAltManager = Nothing
        httpConfigCheckResponse _ _ = return ()
    return HttpConfig {..}

instance Show HttpConfig where
  show HttpConfig {..} =
    "HttpConfig\n" ++
    "{ httpConfigProxy=" ++ show httpConfigProxy ++ "\n" ++
    ", httpRedirectCount=" ++ show httpConfigRedirectCount ++ "\n" ++
    ", httpConfigAltManager=<cannot be shown>\n" ++
    ", httpConfigCheckResponse=<cannot be shown>}\n"

instance Arbitrary L.Proxy where
  arbitrary = L.Proxy <$> arbitrary <*> arbitrary

instance Arbitrary ByteString where
  arbitrary = B.pack <$> arbitrary

instance Arbitrary BL.ByteString where
  arbitrary = BL.pack <$> arbitrary

instance Arbitrary Text where
  arbitrary = T.pack <$> arbitrary

instance Show (Option scheme) where
  show _ = "<cannot be shown>"

data Thing = Thing
  { _thingBool :: Bool
  , _thingText :: Text
  } deriving (Eq, Show, Generic)

instance ToJSON Thing

instance Arbitrary Thing where
  arbitrary = Thing <$> arbitrary <*> arbitrary

instance Arbitrary L.CookieJar where
  arbitrary = L.createCookieJar <$> arbitrary

instance Arbitrary L.Cookie where
  arbitrary = do
    cookie_name          <- arbitrary
    cookie_value         <- arbitrary
    cookie_expiry_time   <- arbitrary
    cookie_domain        <- arbitrary
    cookie_path          <- arbitrary
    cookie_creation_time <- arbitrary
    cookie_last_access_time <- arbitrary
    cookie_persistent    <- arbitrary
    cookie_host_only     <- arbitrary
    cookie_secure_only   <- arbitrary
    cookie_http_only     <- arbitrary
    return L.Cookie {..}

instance Arbitrary UTCTime where
  arbitrary = UTCTime <$> arbitrary <*> arbitrary

instance Arbitrary Day where
  arbitrary = ModifiedJulianDay <$> arbitrary

instance Arbitrary DiffTime where
  arbitrary = secondsToDiffTime <$> arbitrary

----------------------------------------------------------------------------
-- Helpers

-- | 'req' that just returns the prepared 'L.Request'.

req_
  :: ( MonadHttp   m
     , HttpMethod  method
     , HttpBody    body
     , HttpBodyAllowed (AllowsBody method) (ProvidesBody body) )
  => method            -- ^ HTTP method
  -> Url scheme        -- ^ 'Url' — location of resource
  -> body              -- ^ Body of the request
  -> Option scheme     -- ^ Collection of optional parameters
  -> m L.Request       -- ^ Vanilla request
req_ method url' body options =
  responseRequest `liftM` req method url' body returnRequest options

-- | A dummy 'Url'.

url :: Url 'Https
url = https "httpbin.org"

-- | Percent encode given 'Text'.

urlEncode :: Text -> ByteString
urlEncode = Y.urlEncode False . T.encodeUtf8

-- | Build URL path from given path pieces.

encodePathPieces :: [Text] -> ByteString
encodePathPieces = BL.toStrict . BB.toLazyByteString . Y.encodePathSegments

-- | Assemble entire URL.

assembleUrl
  :: Scheme            -- ^ Scheme
  -> Text              -- ^ Host
  -> [Text]            -- ^ Path pieces
  -> [(Text, Maybe Text)] -- ^ Query parameters
  -> (ByteString, ByteString, ByteString) -- ^ URL, path, query string
assembleUrl scheme' host' pathPieces queryParams =
  (scheme <> host <> path <> queryString, path, queryString)
  where
    scheme = case scheme' of
      Http  -> "http://"
      Https -> "https://"
    host        = urlEncode host'
    path        = encodePathPieces pathPieces
    queryString = Y.renderQuery True (Y.queryTextToQuery queryParams)

renderQuery :: [(Text, Maybe Text)] -> BL.ByteString
renderQuery = BL.fromStrict . Y.renderQuery False . Y.queryTextToQuery

-- | Check if collection of query params is well-formed.

wellFormed :: [(Text, Maybe Text)] -> Bool
wellFormed = all (not . T.null . fst)

-- | Convert collection of query parameters to 'FormUrlEncodedParam' thing.

formUrlEnc :: [(Text, Maybe Text)] -> FormUrlEncodedParam
formUrlEnc = foldMap (uncurry queryParam)

-- | Get “Authorization” basic auth header given username and password.

basicAuthHeader :: ByteString -> ByteString -> ByteString
basicAuthHeader username password =
  fromJust . lookup Y.hAuthorization . L.requestHeaders $
    L.applyBasicAuth username password L.defaultRequest
