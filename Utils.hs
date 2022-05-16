module Utils where

import           AbsGengo

mainFnIdent = Ident "main"

builtInNames = ["print"]

getArgIdent :: Arg -> Ident
getArgIdent (VArg _ _ ident) = ident
getArgIdent (RefArg _ _ ident) = ident

getTopDefIdent :: TopDef -> Ident
getTopDefIdent (FnDef _ ident _ _ _) = ident
