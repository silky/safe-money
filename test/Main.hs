{-# LANGUAGE CPP #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE PolyKinds #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE UndecidableInstances #-}
{-# LANGUAGE TypeFamilies #-}

module Main where

import qualified Test.Tasty as Tasty
import qualified Test.Tasty.Runners as Tasty
import Test.Tasty.QuickCheck ((===), (==>))
import qualified Test.Tasty.QuickCheck as QC

import qualified Data.Aeson as Ae
import qualified Data.Binary as Binary
import qualified Data.ByteString.Lazy as BSL
import Data.Maybe (catMaybes, isJust, isNothing)
import Data.Proxy (Proxy(Proxy))
import qualified Data.Serialize as Cereal
import GHC.TypeLits (Nat, Symbol, KnownSymbol, symbolVal)

#ifdef VERSION_store
import qualified Data.Store as Store
#endif

import qualified Money

--------------------------------------------------------------------------------

instance
  ( Money.GoodScale scale
  ) => QC.Arbitrary (Money.Discrete' currency scale) where
  arbitrary = fmap fromInteger QC.arbitrary
  shrink = fmap fromInteger . QC.shrink . toInteger

instance QC.Arbitrary Money.DiscreteRep where
  arbitrary = do
    let md = Money.mkDiscreteRep <$> QC.arbitrary <*> QC.arbitrary
                                 <*> QC.arbitrary <*> QC.arbitrary
    Just x <- QC.suchThat md isJust
    pure x
  shrink = \x -> Money.withDiscreteRep x (map Money.toDiscreteRep . QC.shrink)

instance QC.Arbitrary (Money.Dense currency) where
  arbitrary = do
    Just x <- QC.suchThat (Money.dense <$> QC.arbitrary) isJust
    pure x
  shrink = catMaybes . fmap Money.dense . QC.shrink . toRational

instance QC.Arbitrary Money.DenseRep where
  arbitrary = do
    let md = Money.mkDenseRep <$> QC.arbitrary <*> QC.arbitrary <*> QC.arbitrary
    Just x <- QC.suchThat md isJust
    pure x
  shrink = \x -> Money.withDenseRep x (map Money.toDenseRep . QC.shrink)

instance QC.Arbitrary (Money.ExchangeRate src dst) where
  arbitrary = do
    Just x <- QC.suchThat (fmap Money.exchangeRate QC.arbitrary) isJust
    pure x
  shrink =
    catMaybes . fmap Money.exchangeRate . QC.shrink . Money.fromExchangeRate

instance QC.Arbitrary Money.ExchangeRateRep where
  arbitrary = do
    let md = Money.mkExchangeRateRep <$> QC.arbitrary <*> QC.arbitrary
                                     <*> QC.arbitrary <*> QC.arbitrary
    Just x <- QC.suchThat md isJust
    pure x
  shrink = \x ->
    Money.withExchangeRateRep x (map Money.toExchangeRateRep . QC.shrink)

--------------------------------------------------------------------------------

main :: IO ()
main =  Tasty.defaultMainWithIngredients
  [ Tasty.consoleTestReporter
  , Tasty.listingTests
  ] tests

tests :: Tasty.TestTree
tests =
  Tasty.testGroup "root"
  [ testCurrencies
  , testCurrencyUnits
  , testExchange
  ]

testCurrencies :: Tasty.TestTree
testCurrencies =
  Tasty.testGroup "Currency"
  [ testDense (Proxy :: Proxy "BTC")  -- A cryptocurrency.
  , testDense (Proxy :: Proxy "USD")  -- A fiat currency with decimal fractions.
  , testDense (Proxy :: Proxy "VUV")  -- A fiat currency with non-decimal fractions.
  , testDense (Proxy :: Proxy "XAU")  -- A precious metal.
  ]

testCurrencyUnits :: Tasty.TestTree
testCurrencyUnits =
  Tasty.testGroup "Currency units"
  [ testDiscrete (Proxy :: Proxy "BTC") (Proxy :: Proxy "BTC")
  , testDiscrete (Proxy :: Proxy "BTC") (Proxy :: Proxy "satoshi")
  , testDiscrete (Proxy :: Proxy "BTC") (Proxy :: Proxy "bitcoin")
  , testDiscrete (Proxy :: Proxy "USD") (Proxy :: Proxy "USD")
  , testDiscrete (Proxy :: Proxy "USD") (Proxy :: Proxy "cent")
  , testDiscrete (Proxy :: Proxy "USD") (Proxy :: Proxy "dollar")
  , testDiscrete (Proxy :: Proxy "VUV") (Proxy :: Proxy "vatu")
  , testDiscrete (Proxy :: Proxy "XAU") (Proxy :: Proxy "micrograin")
  , testDiscrete (Proxy :: Proxy "XAU") (Proxy :: Proxy "milligrain")
  , testDiscrete (Proxy :: Proxy "XAU") (Proxy :: Proxy "grain")
  ]

testDense
  :: forall currency
  .  KnownSymbol currency
  => Proxy currency
  -> Tasty.TestTree
testDense pc =
  Tasty.testGroup ("Dense " ++ show (symbolVal pc))
  [ QC.testProperty "read . show == id" $
      QC.forAll QC.arbitrary $ \(x :: Money.Dense currency) ->
         x === read (show x)
  , QC.testProperty "fromDenseRep . denseRep == Just" $
      QC.forAll QC.arbitrary $ \(x :: Money.Dense currency) ->
         Just x === Money.fromDenseRep (Money.toDenseRep x)
  , QC.testProperty "fromDenseRep works only for same currency" $
      QC.forAll QC.arbitrary $ \(dr :: Money.DenseRep) ->
        (Money.denseRepCurrency dr /= symbolVal pc)
           ==> isNothing (Money.fromDenseRep dr :: Maybe (Money.Dense currency))
  , QC.testProperty "withDenseRep" $
      QC.forAll QC.arbitrary $ \(x :: Money.Dense currency) ->
        let dr = Money.toDenseRep x
        in Money.withDenseRep dr $ \x' ->
             (show x, dr, Money.toDenseRep (x + 1))
                === (show x', Money.toDenseRep x', Money.toDenseRep (x' + 1))

  , QC.testProperty "Aeson encoding roundtrip" $
      QC.forAll QC.arbitrary $ \(x :: Money.Dense currency) ->
         Just x === Ae.decode (Ae.encode x)
  , QC.testProperty "Aeson encoding roundtrip (DenseRep)" $
      QC.forAll QC.arbitrary $ \(x :: Money.Dense currency) ->
         let x' = Money.toDenseRep x
         in Just x' === Ae.decode (Ae.encode x')
  , QC.testProperty "Aeson encoding roundtrip (Dense through DenseRep)" $
      QC.forAll QC.arbitrary $ \(x :: Money.Dense currency) ->
         Just x === Ae.decode (Ae.encode (Money.toDenseRep x))
  , QC.testProperty "Aeson encoding roundtrip (DenseRep through Dense)" $
      QC.forAll QC.arbitrary $ \(x :: Money.Dense currency) ->
         Just (Money.toDenseRep x) === Ae.decode (Ae.encode x)

  , QC.testProperty "Binary encoding roundtrip" $
      QC.forAll QC.arbitrary $ \(x :: Money.Dense currency) ->
         let Right (_,_,y) = Binary.decodeOrFail (Binary.encode x)
         in x === y
  , QC.testProperty "Binary encoding roundtrip (DenseRep)" $
      QC.forAll QC.arbitrary $ \(x :: Money.Dense currency) ->
         let x' = Money.toDenseRep x
             bs = Binary.encode x'
         in Right (mempty, BSL.length bs, x') === Binary.decodeOrFail bs
  , QC.testProperty "Binary encoding roundtrip (Dense through DenseRep)" $
      QC.forAll QC.arbitrary $ \(x :: Money.Dense currency) ->
         let x' = Money.toDenseRep x
             bs = Binary.encode x'
         in Right (mempty, BSL.length bs, x) === Binary.decodeOrFail bs
  , QC.testProperty "Binary encoding roundtrip (DenseRep through Dense)" $
      QC.forAll QC.arbitrary $ \(x :: Money.Dense currency) ->
         let x' = Money.toDenseRep x
             bs = Binary.encode x
         in Right (mempty, BSL.length bs, x') === Binary.decodeOrFail bs

  , QC.testProperty "Cereal encoding roundtrip" $
      QC.forAll QC.arbitrary $ \(x :: Money.Dense currency) ->
         Right x === Cereal.decode (Cereal.encode x)
  , QC.testProperty "Cereal encoding roundtrip (DenseRep)" $
      QC.forAll QC.arbitrary $ \(x :: Money.Dense currency) ->
         let x' = Money.toDenseRep x
         in Right x' === Cereal.decode (Cereal.encode x')
  , QC.testProperty "Cereal encoding roundtrip (Dense through DenseRep)" $
      QC.forAll QC.arbitrary $ \(x :: Money.Dense currency) ->
         Right x === Cereal.decode (Cereal.encode (Money.toDenseRep x))
  , QC.testProperty "Cereal encoding roundtrip (DenseRep through Dense)" $
      QC.forAll QC.arbitrary $ \(x :: Money.Dense currency) ->
         Right (Money.toDenseRep x) === Cereal.decode (Cereal.encode x)

#ifdef VERSION_store
  , QC.testProperty "Store encoding roundtrip" $
      QC.forAll QC.arbitrary $ \(x :: Money.Dense currency) ->
         Right x === Store.decode (Store.encode x)
  , QC.testProperty "Store encoding roundtrip (DenseRep)" $
      QC.forAll QC.arbitrary $ \(x :: Money.Dense currency) ->
         let x' = Money.toDenseRep x
         in Right x' === Store.decode (Store.encode x')
  , QC.testProperty "Store encoding roundtrip (Dense through DenseRep)" $
      QC.forAll QC.arbitrary $ \(x :: Money.Dense currency) ->
         Right x === Store.decode (Store.encode (Money.toDenseRep x))
  , QC.testProperty "Store encoding roundtrip (DenseRep through Dense)" $
      QC.forAll QC.arbitrary $ \(x :: Money.Dense currency) ->
         Right (Money.toDenseRep x) === Store.decode (Store.encode x)
#endif
  ]

testExchange :: Tasty.TestTree
testExchange =
  Tasty.testGroup "Exchange"
  [ testExchangeRate (Proxy :: Proxy "BTC") (Proxy :: Proxy "BTC")
  , testExchangeRate (Proxy :: Proxy "BTC") (Proxy :: Proxy "USD")
  , testExchangeRate (Proxy :: Proxy "BTC") (Proxy :: Proxy "VUV")
  , testExchangeRate (Proxy :: Proxy "BTC") (Proxy :: Proxy "XAU")
  , testExchangeRate (Proxy :: Proxy "USD") (Proxy :: Proxy "BTC")
  , testExchangeRate (Proxy :: Proxy "USD") (Proxy :: Proxy "USD")
  , testExchangeRate (Proxy :: Proxy "USD") (Proxy :: Proxy "VUV")
  , testExchangeRate (Proxy :: Proxy "USD") (Proxy :: Proxy "XAU")
  , testExchangeRate (Proxy :: Proxy "VUV") (Proxy :: Proxy "BTC")
  , testExchangeRate (Proxy :: Proxy "VUV") (Proxy :: Proxy "USD")
  , testExchangeRate (Proxy :: Proxy "VUV") (Proxy :: Proxy "VUV")
  , testExchangeRate (Proxy :: Proxy "VUV") (Proxy :: Proxy "XAU")
  , testExchangeRate (Proxy :: Proxy "XAU") (Proxy :: Proxy "BTC")
  , testExchangeRate (Proxy :: Proxy "XAU") (Proxy :: Proxy "USD")
  , testExchangeRate (Proxy :: Proxy "XAU") (Proxy :: Proxy "VUV")
  , testExchangeRate (Proxy :: Proxy "XAU") (Proxy :: Proxy "XAU")
  ]

testDiscrete
  :: forall (currency :: Symbol) (unit :: Symbol)
  .  ( Money.GoodScale (Money.Scale currency unit)
     , KnownSymbol currency
     , KnownSymbol unit )
  => Proxy currency
  -> Proxy unit
  -> Tasty.TestTree
testDiscrete pc pu =
  Tasty.testGroup ("Discrete " ++ show (symbolVal pc) ++ " "
                               ++ show (symbolVal pu))
  [ testRounding pc pu
  , QC.testProperty "read . show == id" $
      QC.forAll QC.arbitrary $ \(x :: Money.Discrete currency unit) ->
         x === read (show x)
  , QC.testProperty "fromDiscreteRep . discreteRep == Just" $
      QC.forAll QC.arbitrary $ \(x :: Money.Discrete currency unit) ->
         Just x === Money.fromDiscreteRep (Money.toDiscreteRep x)
  , QC.testProperty "fromDiscreteRep works only for same currency and scale" $
      QC.forAll QC.arbitrary $ \(dr :: Money.DiscreteRep) ->
        ((Money.discreteRepCurrency dr /= symbolVal pc) &&
         (Money.discreteRepScale dr /=
             Money.scale (Proxy :: Proxy (Money.Scale currency unit)))
        ) ==> isNothing (Money.fromDiscreteRep dr
                          :: Maybe (Money.Discrete currency unit))
  , QC.testProperty "withDiscreteRep" $
      QC.forAll QC.arbitrary $ \(x :: Money.Discrete currency unit) ->
        let dr = Money.toDiscreteRep x
        in ( Money.withDiscreteRep dr $ \x' ->
                (show x, dr, Money.toDiscreteRep (x + 1))
                   === (show x', Money.toDiscreteRep x', Money.toDiscreteRep (x' + 1))
           ) :: QC.Property

  , QC.testProperty "Aeson encoding roundtrip" $
      QC.forAll QC.arbitrary $ \(x :: Money.Discrete currency unit) ->
         Just x === Ae.decode (Ae.encode x)
  , QC.testProperty "Aeson encoding roundtrip (DiscreteRep)" $
      QC.forAll QC.arbitrary $ \(x :: Money.Discrete currency unit) ->
         let x' = Money.toDiscreteRep x
         in Just x' === Ae.decode (Ae.encode x')
  , QC.testProperty "Aeson encoding roundtrip (Discrete through DiscreteRep)" $
      QC.forAll QC.arbitrary $ \(x :: Money.Discrete currency unit) ->
         Just x === Ae.decode (Ae.encode (Money.toDiscreteRep x))
  , QC.testProperty "Aeson encoding roundtrip (DiscreteRep through Discrete)" $
      QC.forAll QC.arbitrary $ \(x :: Money.Discrete currency unit) ->
         Just (Money.toDiscreteRep x) === Ae.decode (Ae.encode x)

  , QC.testProperty "Binary encoding roundtrip" $
      QC.forAll QC.arbitrary $ \(x :: Money.Discrete currency unit) ->
         let Right (_,_,y) = Binary.decodeOrFail (Binary.encode x)
         in x === y
  , QC.testProperty "Binary encoding roundtrip (DiscreteRep)" $
      QC.forAll QC.arbitrary $ \(x :: Money.Discrete currency unit) ->
         let x' = Money.toDiscreteRep x
             bs = Binary.encode x'
         in Right (mempty, BSL.length bs, x') === Binary.decodeOrFail bs
  , QC.testProperty "Binary encoding roundtrip (Discrete through DiscreteRep)" $
      QC.forAll QC.arbitrary $ \(x :: Money.Discrete currency unit) ->
         let x' = Money.toDiscreteRep x
             bs = Binary.encode x'
         in Right (mempty, BSL.length bs, x) === Binary.decodeOrFail bs
  , QC.testProperty "Binary encoding roundtrip (DiscreteRep through Discrete)" $
      QC.forAll QC.arbitrary $ \(x :: Money.Discrete currency unit) ->
         let x' = Money.toDiscreteRep x
             bs = Binary.encode x
         in Right (mempty, BSL.length bs, x') === Binary.decodeOrFail bs

  , QC.testProperty "Cereal encoding roundtrip" $
      QC.forAll QC.arbitrary $ \(x :: Money.Discrete currency unit) ->
         Right x === Cereal.decode (Cereal.encode x)
  , QC.testProperty "Cereal encoding roundtrip (DiscreteRep)" $
      QC.forAll QC.arbitrary $ \(x :: Money.Discrete currency unit) ->
         let x' = Money.toDiscreteRep x
         in Right x' === Cereal.decode (Cereal.encode x')
  , QC.testProperty "Cereal encoding roundtrip (Discrete through DiscreteRep)" $
      QC.forAll QC.arbitrary $ \(x :: Money.Discrete currency unit) ->
         Right x === Cereal.decode (Cereal.encode (Money.toDiscreteRep x))
  , QC.testProperty "Cereal encoding roundtrip (DiscreteRep through Discrete)" $
      QC.forAll QC.arbitrary $ \(x :: Money.Discrete currency unit) ->
         Right (Money.toDiscreteRep x) === Cereal.decode (Cereal.encode x)

#ifdef VERSION_store
  , QC.testProperty "Store encoding roundtrip" $
      QC.forAll QC.arbitrary $ \(x :: Money.Discrete currency unit) ->
         Right x === Store.decode (Store.encode x)
  , QC.testProperty "Store encoding roundtrip (DiscreteRep)" $
      QC.forAll QC.arbitrary $ \(x :: Money.Discrete currency unit) ->
         let x' = Money.toDiscreteRep x
         in Right x' === Store.decode (Store.encode x')
  , QC.testProperty "Store encoding roundtrip (Discrete through DiscreteRep)" $
      QC.forAll QC.arbitrary $ \(x :: Money.Discrete currency unit) ->
         Right x === Store.decode (Store.encode (Money.toDiscreteRep x))
  , QC.testProperty "Store encoding roundtrip (DiscreteRep through Discrete)" $
      QC.forAll QC.arbitrary $ \(x :: Money.Discrete currency unit) ->
         Right (Money.toDiscreteRep x) === Store.decode (Store.encode x)
#endif
  ]

testExchangeRate
  :: forall (src :: Symbol) (dst :: Symbol)
  .  (KnownSymbol src, KnownSymbol dst)
  => Proxy src
  -> Proxy dst
  -> Tasty.TestTree
testExchangeRate ps pd =
  Tasty.testGroup ("ExchangeRate " ++ show (symbolVal ps) ++ " "
                                   ++ show (symbolVal pd))
  [ QC.testProperty "read . show == id" $
      QC.forAll QC.arbitrary $ \(xr :: Money.ExchangeRate src dst) ->
         xr === read (show xr)
  , QC.testProperty "flipExchangeRate . flipExchangeRate == id" $
      QC.forAll QC.arbitrary $ \(xr :: Money.ExchangeRate src dst) ->
         let xr' = Money.flipExchangeRate xr
         in (Money.fromExchangeRate xr /= Money.fromExchangeRate xr')
               ==> (xr === Money.flipExchangeRate xr')
  , QC.testProperty "exchange (flipExchangeRate x) . exchange x == id" $
      QC.forAll QC.arbitrary $
         \( c0 :: Money.Dense src
          , xr :: Money.ExchangeRate src dst
          ) -> c0 === Money.exchange (Money.flipExchangeRate xr)
                                     (Money.exchange xr c0)
  , QC.testProperty "x == 1 ===> exchange x == id" $
      QC.forAll QC.arbitrary $
         \( c0 :: Money.Dense src
          ) -> let Just xr = Money.exchangeRate 1
               in toRational c0 === toRational (Money.exchange xr c0)
  , QC.testProperty "x /= 1 ===> exchange x /= id" $
      QC.forAll QC.arbitrary $
         \( c0 :: Money.Dense src
          , xr :: Money.ExchangeRate src dst
          ) -> (Money.fromExchangeRate xr /= 1)
                  ==> (toRational c0 /= toRational (Money.exchange xr c0))
  , QC.testProperty "fromExchangeRateRep . exchangeRateRep == Just" $
      QC.forAll QC.arbitrary $ \(x :: Money.ExchangeRate src dst) ->
         Just x === Money.fromExchangeRateRep (Money.toExchangeRateRep x)
  , QC.testProperty "fromExchangeRateRep works only for same currencies" $
      QC.forAll QC.arbitrary $ \(x :: Money.ExchangeRateRep) ->
        ((Money.exchangeRateRepSrcCurrency x /= symbolVal ps) &&
         (Money.exchangeRateRepDstCurrency x /= symbolVal pd))
            ==> isNothing (Money.fromExchangeRateRep x
                            :: Maybe (Money.ExchangeRate src dst))
  , QC.testProperty "withExchangeRateRep" $
      QC.forAll QC.arbitrary $ \(x :: Money.ExchangeRate src dst) ->
        let dr = Money.toExchangeRateRep x
        in Money.withExchangeRateRep dr $ \x' ->
             (show x, dr) === (show x', Money.toExchangeRateRep x')

  , QC.testProperty "Aeson encoding roundtrip" $
      QC.forAll QC.arbitrary $ \(x :: Money.ExchangeRate src dst) ->
         Just x === Ae.decode (Ae.encode x)
  , QC.testProperty "Aeson encoding roundtrip (ExchangeRateRep)" $
      QC.forAll QC.arbitrary $ \(x :: Money.ExchangeRate src dst) ->
         let x' = Money.toExchangeRateRep x
         in Just x' === Ae.decode (Ae.encode x')
  , QC.testProperty "Aeson encoding roundtrip (ExchangeRate through ExchangeRateRep)" $
      QC.forAll QC.arbitrary $ \(x :: Money.ExchangeRate src dst) ->
         Just x === Ae.decode (Ae.encode (Money.toExchangeRateRep x))
  , QC.testProperty "Aeson encoding roundtrip (ExchangeRateRep through ExchangeRate)" $
      QC.forAll QC.arbitrary $ \(x :: Money.ExchangeRate src dst) ->
         Just (Money.toExchangeRateRep x) === Ae.decode (Ae.encode x)

  , QC.testProperty "Binary encoding roundtrip" $
      QC.forAll QC.arbitrary $ \(x :: Money.ExchangeRate src dst) ->
         let Right (_,_,y) = Binary.decodeOrFail (Binary.encode x)
         in x === y
  , QC.testProperty "Binary encoding roundtrip (ExchangeRateRep)" $
      QC.forAll QC.arbitrary $ \(x :: Money.ExchangeRate src dst) ->
         let x' = Money.toExchangeRateRep x
             bs = Binary.encode x'
         in Right (mempty, BSL.length bs, x') === Binary.decodeOrFail bs
  , QC.testProperty "Binary encoding roundtrip (ExchangeRate through ExchangeRateRep)" $
      QC.forAll QC.arbitrary $ \(x :: Money.ExchangeRate src dst) ->
         let x' = Money.toExchangeRateRep x
             bs = Binary.encode x'
         in Right (mempty, BSL.length bs, x) === Binary.decodeOrFail bs
  , QC.testProperty "Binary encoding roundtrip (ExchangeRateRep through ExchangeRate)" $
      QC.forAll QC.arbitrary $ \(x :: Money.ExchangeRate src dst) ->
         let x' = Money.toExchangeRateRep x
             bs = Binary.encode x
         in Right (mempty, BSL.length bs, x') === Binary.decodeOrFail bs

  , QC.testProperty "Cereal encoding roundtrip" $
      QC.forAll QC.arbitrary $ \(x :: Money.ExchangeRate src dst) ->
         Right x === Cereal.decode (Cereal.encode x)
  , QC.testProperty "Cereal encoding roundtrip (ExchangeRateRep)" $
      QC.forAll QC.arbitrary $ \(x :: Money.ExchangeRate src dst) ->
         let x' = Money.toExchangeRateRep x
         in Right x' === Cereal.decode (Cereal.encode x')
  , QC.testProperty "Cereal encoding roundtrip (ExchangeRate through ExchangeRateRep)" $
      QC.forAll QC.arbitrary $ \(x :: Money.ExchangeRate src dst) ->
         Right x === Cereal.decode (Cereal.encode (Money.toExchangeRateRep x))
  , QC.testProperty "Cereal encoding roundtrip (ExchangeRateRep through ExchangeRate)" $
      QC.forAll QC.arbitrary $ \(x :: Money.ExchangeRate src dst) ->
         Right (Money.toExchangeRateRep x) === Cereal.decode (Cereal.encode x)

#ifdef VERSION_store
  , QC.testProperty "Store encoding roundtrip" $
      QC.forAll QC.arbitrary $ \(x :: Money.ExchangeRate src dst) ->
         Right x === Store.decode (Store.encode x)
  , QC.testProperty "Store encoding roundtrip (ExchangeRateRep)" $
      QC.forAll QC.arbitrary $ \(x :: Money.ExchangeRate src dst) ->
         let x' = Money.toExchangeRateRep x
         in Right x' === Store.decode (Store.encode x')
  , QC.testProperty "Store encoding roundtrip (ExchangeRate through ExchangeRateRep)" $
      QC.forAll QC.arbitrary $ \(x :: Money.ExchangeRate src dst) ->
         Right x === Store.decode (Store.encode (Money.toExchangeRateRep x))
  , QC.testProperty "Store encoding roundtrip (ExchangeRateRep through ExchangeRate)" $
      QC.forAll QC.arbitrary $ \(x :: Money.ExchangeRate src dst) ->
         Right (Money.toExchangeRateRep x) === Store.decode (Store.encode x)
#endif
  ]

testRounding
  :: forall (currency :: Symbol) (unit :: Symbol)
  .  (Money.GoodScale (Money.Scale currency unit), KnownSymbol currency)
  => Proxy currency
  -> Proxy unit
  -> Tasty.TestTree
testRounding _ _ =
    Tasty.testGroup "Rounding"
    [ QC.testProperty "floor"    $ QC.forAll QC.arbitrary (g Money.floor)
    , QC.testProperty "ceiling"  $ QC.forAll QC.arbitrary (g Money.ceiling)
    , QC.testProperty "round"    $ QC.forAll QC.arbitrary (g Money.round)
    , QC.testProperty "truncate" $ QC.forAll QC.arbitrary (g Money.truncate)
    ]
  where
    g f = \(x :: Money.Dense currency) -> x === case f x of
      (y, Nothing) -> Money.fromDiscrete (y :: Money.Discrete currency unit)
      (y, Just z)  -> Money.fromDiscrete y + z
