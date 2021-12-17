module Search where

import Data.SearchEngine
import qualified Data.Text as T
import Data.Ix (Ix)

data MockDoc = MockDoc {
    ref :: Int,
    title :: T.Text,
    contents :: T.Text
}

type Ref = Int

data Field = Title | AsContents deriving (Eq, Ord, Enum, Bounded, Ix, Show)

someDocs :: [MockDoc]
someDocs =
    let toTxt n = T.pack . show $ n
    in  map (\n -> MockDoc n ("title for " `T.append` toTxt (n+1)) ("val for " `T.append` toTxt (n+1))) ([0..5] :: [Int])

defaultSearchRankParameters :: SearchRankParameters Field NoFeatures
defaultSearchRankParameters =
    SearchRankParameters {
        paramK1 = 1.2,
        paramB = const 0.75,
        paramFieldWeights = const 20,
        paramFeatureWeights = noFeatures,
        paramFeatureFunctions = noFeatures,
        paramResultsetSoftLimit = 200,
        paramResultsetHardLimit = 400,
        paramAutosuggestPrefilterLimit  = 500,
        paramAutosuggestPostfilterLimit = 500
    }

defaultSearchConfig :: SearchConfig MockDoc Int Field NoFeatures
defaultSearchConfig =
    SearchConfig    {
        documentKey = ref,
        extractDocumentTerms = xtract,
        transformQueryTerm = xform,
        documentFeatureValue = const noFeatures
    }
    where
        xtract doc _ = T.words $ title doc `T.append` contents doc
        xform t _ = T.toCaseFold t

type FeedsSearch = SearchEngine MockDoc Ref Field NoFeatures

makeSearch :: [MockDoc] -> FeedsSearch
makeSearch feeds = insertDocs feeds $ initSearchEngine defaultSearchConfig defaultSearchRankParameters

test_search_engine :: IO ()
test_search_engine = 
    let !initial = makeSearch someDocs
        res = query initial ["2"]
    in  print res