module Main where

import           Data.Text.IO                   (getContents)
import           Data.Text.Prettyprint.Doc
import           Data.Text.Prettyprint.Doc.Util
import           Nixfmt.Parser
import           Nixfmt.Pretty                  ()
import           Prelude                        hiding (getContents)
import           System.IO                      (hPutStr, stderr)
import           Text.Megaparsec

main :: IO ()
main = do
    contents <- getContents
    case parse nixFile "<stdin>" contents of
        Left err     -> hPutStr stderr $ errorBundlePretty err
        Right parsed -> putDocW 80 $ pretty parsed
