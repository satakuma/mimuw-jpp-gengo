module Utils where

import           AbsGengo

type Pos = BNFC'Position

mainFnIdent = Ident "main"

builtInNames = ["print"]

getArgIdent :: Arg -> Ident
getArgIdent (Arg _ _ ident) = ident

getTopDefIdent :: TopDef -> Ident
getTopDefIdent (FnDef _ ident _ _ _) = ident

argToArgType :: Arg -> ArgType
argToArgType (Arg _ at _) = at
