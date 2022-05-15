-- File generated by the BNF Converter (bnfc 2.9.3).

{-# LANGUAGE CPP #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE LambdaCase #-}
#if __GLASGOW_HASKELL__ <= 708
{-# LANGUAGE OverlappingInstances #-}
#endif

-- | Pretty-printer for PrintGengo.

module PrintGengo where

import Prelude
  ( ($), (.)
  , Bool(..), (==), (<)
  , Int, Integer, Double, (+), (-), (*)
  , String, (++)
  , ShowS, showChar, showString
  , all, elem, foldr, id, map, null, replicate, shows, span
  )
import Data.Char ( Char, isSpace )
import qualified AbsGengo

-- | The top-level printing method.

printTree :: Print a => a -> String
printTree = render . prt 0

type Doc = [ShowS] -> [ShowS]

doc :: ShowS -> Doc
doc = (:)

render :: Doc -> String
render d = rend 0 False (map ($ "") $ d []) ""
  where
  rend
    :: Int        -- ^ Indentation level.
    -> Bool       -- ^ Pending indentation to be output before next character?
    -> [String]
    -> ShowS
  rend i p = \case
      "["      :ts -> char '[' . rend i False ts
      "("      :ts -> char '(' . rend i False ts
      "{"      :ts -> onNewLine i     p . showChar   '{'  . new (i+1) ts
      "}" : ";":ts -> onNewLine (i-1) p . showString "};" . new (i-1) ts
      "}"      :ts -> onNewLine (i-1) p . showChar   '}'  . new (i-1) ts
      [";"]        -> char ';'
      ";"      :ts -> char ';' . new i ts
      t  : ts@(s:_) | closingOrPunctuation s
                   -> pending . showString t . rend i False ts
      t        :ts -> pending . space t      . rend i False ts
      []           -> id
    where
    -- Output character after pending indentation.
    char :: Char -> ShowS
    char c = pending . showChar c

    -- Output pending indentation.
    pending :: ShowS
    pending = if p then indent i else id

  -- Indentation (spaces) for given indentation level.
  indent :: Int -> ShowS
  indent i = replicateS (2*i) (showChar ' ')

  -- Continue rendering in new line with new indentation.
  new :: Int -> [String] -> ShowS
  new j ts = showChar '\n' . rend j True ts

  -- Make sure we are on a fresh line.
  onNewLine :: Int -> Bool -> ShowS
  onNewLine i p = (if p then id else showChar '\n') . indent i

  -- Separate given string from following text by a space (if needed).
  space :: String -> ShowS
  space t s =
    case (all isSpace t', null spc, null rest) of
      (True , _   , True ) -> []              -- remove trailing space
      (False, _   , True ) -> t'              -- remove trailing space
      (False, True, False) -> t' ++ ' ' : s   -- add space if none
      _                    -> t' ++ s
    where
      t'          = showString t []
      (spc, rest) = span isSpace s

  closingOrPunctuation :: String -> Bool
  closingOrPunctuation [c] = c `elem` closerOrPunct
  closingOrPunctuation _   = False

  closerOrPunct :: String
  closerOrPunct = ")],;"

parenth :: Doc -> Doc
parenth ss = doc (showChar '(') . ss . doc (showChar ')')

concatS :: [ShowS] -> ShowS
concatS = foldr (.) id

concatD :: [Doc] -> Doc
concatD = foldr (.) id

replicateS :: Int -> ShowS -> ShowS
replicateS n f = concatS (replicate n f)

-- | The printer class does the job.

class Print a where
  prt :: Int -> a -> Doc

instance {-# OVERLAPPABLE #-} Print a => Print [a] where
  prt i = concatD . map (prt i)

instance Print Char where
  prt _ c = doc (showChar '\'' . mkEsc '\'' c . showChar '\'')

instance Print String where
  prt _ = printString

printString :: String -> Doc
printString s = doc (showChar '"' . concatS (map (mkEsc '"') s) . showChar '"')

mkEsc :: Char -> Char -> ShowS
mkEsc q = \case
  s | s == q -> showChar '\\' . showChar s
  '\\' -> showString "\\\\"
  '\n' -> showString "\\n"
  '\t' -> showString "\\t"
  s -> showChar s

prPrec :: Int -> Int -> Doc -> Doc
prPrec i j = if j < i then parenth else id

instance Print Integer where
  prt _ x = doc (shows x)

instance Print Double where
  prt _ x = doc (shows x)

instance Print AbsGengo.Ident where
  prt _ (AbsGengo.Ident i) = doc $ showString i
instance Print (AbsGengo.Program' a) where
  prt i = \case
    AbsGengo.Program _ topdefs -> prPrec i 0 (concatD [prt 0 topdefs])

instance Print (AbsGengo.TopDef' a) where
  prt i = \case
    AbsGengo.FnDef _ id_ args type_ block -> prPrec i 0 (concatD [doc (showString "fn"), prt 0 id_, doc (showString "("), prt 0 args, doc (showString ")"), doc (showString "->"), prt 0 type_, prt 0 block])
    AbsGengo.GnDef _ id_ args type_ block -> prPrec i 0 (concatD [doc (showString "gn"), prt 0 id_, doc (showString "("), prt 0 args, doc (showString ")"), doc (showString "->"), prt 0 type_, prt 0 block])

instance Print [AbsGengo.TopDef' a] where
  prt _ [] = concatD []
  prt _ [x] = concatD [prt 0 x]
  prt _ (x:xs) = concatD [prt 0 x, prt 0 xs]

instance Print (AbsGengo.Arg' a) where
  prt i = \case
    AbsGengo.VArg _ type_ id_ -> prPrec i 0 (concatD [prt 0 type_, prt 0 id_])
    AbsGengo.RefArg _ type_ id_ -> prPrec i 0 (concatD [prt 0 type_, doc (showString "&"), prt 0 id_])

instance Print [AbsGengo.Arg' a] where
  prt _ [] = concatD []
  prt _ [x] = concatD [prt 0 x]
  prt _ (x:xs) = concatD [prt 0 x, doc (showString ","), prt 0 xs]

instance Print (AbsGengo.Block' a) where
  prt i = \case
    AbsGengo.Block _ stmts -> prPrec i 0 (concatD [doc (showString "{"), prt 0 stmts, doc (showString "}")])

instance Print [AbsGengo.Stmt' a] where
  prt _ [] = concatD []
  prt _ (x:xs) = concatD [prt 0 x, prt 0 xs]

instance Print (AbsGengo.Stmt' a) where
  prt i = \case
    AbsGengo.Empty _ -> prPrec i 0 (concatD [doc (showString ";")])
    AbsGengo.BStmt _ block -> prPrec i 0 (concatD [prt 0 block])
    AbsGengo.Init _ type_ id_ expr -> prPrec i 0 (concatD [prt 0 type_, prt 0 id_, doc (showString "="), prt 0 expr, doc (showString ";")])
    AbsGengo.Ass _ id_ expr -> prPrec i 0 (concatD [prt 0 id_, doc (showString "="), prt 0 expr, doc (showString ";")])
    AbsGengo.Ret _ expr -> prPrec i 0 (concatD [doc (showString "return"), prt 0 expr, doc (showString ";")])
    AbsGengo.Yield _ expr -> prPrec i 0 (concatD [doc (showString "yield"), prt 0 expr, doc (showString ";")])
    AbsGengo.Break _ -> prPrec i 0 (concatD [doc (showString "break"), doc (showString ";")])
    AbsGengo.Continue _ -> prPrec i 0 (concatD [doc (showString "continue"), doc (showString ";")])
    AbsGengo.Cond _ if_ -> prPrec i 0 (concatD [prt 0 if_])
    AbsGengo.While _ expr block -> prPrec i 0 (concatD [doc (showString "while"), doc (showString "("), prt 0 expr, doc (showString ")"), prt 0 block])
    AbsGengo.For _ id_ expr block -> prPrec i 0 (concatD [doc (showString "for"), prt 0 id_, doc (showString "in"), doc (showString "("), prt 0 expr, doc (showString ")"), prt 0 block])
    AbsGengo.SExp _ expr -> prPrec i 0 (concatD [prt 0 expr, doc (showString ";")])
    AbsGengo.NestFn _ topdef -> prPrec i 0 (concatD [prt 0 topdef])

instance Print (AbsGengo.If' a) where
  prt i = \case
    AbsGengo.If _ expr block -> prPrec i 0 (concatD [doc (showString "if"), doc (showString "("), prt 0 expr, doc (showString ")"), prt 0 block])
    AbsGengo.IfElse _ expr block else_ -> prPrec i 0 (concatD [doc (showString "if"), doc (showString "("), prt 0 expr, doc (showString ")"), prt 0 block, doc (showString "else"), prt 0 else_])

instance Print (AbsGengo.Else' a) where
  prt i = \case
    AbsGengo.ElseBlock _ block -> prPrec i 0 (concatD [prt 0 block])
    AbsGengo.ElseIf _ if_ -> prPrec i 0 (concatD [prt 0 if_])

instance Print (AbsGengo.Type' a) where
  prt i = \case
    AbsGengo.Int _ -> prPrec i 0 (concatD [doc (showString "int")])
    AbsGengo.Str _ -> prPrec i 0 (concatD [doc (showString "string")])
    AbsGengo.Bool _ -> prPrec i 0 (concatD [doc (showString "bool")])
    AbsGengo.Generator _ type_ -> prPrec i 0 (concatD [doc (showString "@"), doc (showString "("), prt 0 type_, doc (showString ")")])

instance Print (AbsGengo.Expr' a) where
  prt i = \case
    AbsGengo.EVar _ id_ -> prPrec i 6 (concatD [prt 0 id_])
    AbsGengo.ELitInt _ n -> prPrec i 6 (concatD [prt 0 n])
    AbsGengo.ELitTrue _ -> prPrec i 6 (concatD [doc (showString "true")])
    AbsGengo.ELitFalse _ -> prPrec i 6 (concatD [doc (showString "false")])
    AbsGengo.EApp _ id_ exprs -> prPrec i 6 (concatD [prt 0 id_, doc (showString "("), prt 0 exprs, doc (showString ")")])
    AbsGengo.EString _ str -> prPrec i 6 (concatD [printString str])
    AbsGengo.Neg _ expr -> prPrec i 5 (concatD [doc (showString "-"), prt 6 expr])
    AbsGengo.Not _ expr -> prPrec i 5 (concatD [doc (showString "!"), prt 6 expr])
    AbsGengo.EMul _ expr1 mulop expr2 -> prPrec i 4 (concatD [prt 4 expr1, prt 0 mulop, prt 5 expr2])
    AbsGengo.EAdd _ expr1 addop expr2 -> prPrec i 3 (concatD [prt 3 expr1, prt 0 addop, prt 4 expr2])
    AbsGengo.ERel _ expr1 relop expr2 -> prPrec i 2 (concatD [prt 2 expr1, prt 0 relop, prt 3 expr2])
    AbsGengo.EAnd _ expr1 expr2 -> prPrec i 1 (concatD [prt 2 expr1, doc (showString "&&"), prt 1 expr2])
    AbsGengo.EOr _ expr1 expr2 -> prPrec i 0 (concatD [prt 1 expr1, doc (showString "||"), prt 0 expr2])

instance Print [AbsGengo.Expr' a] where
  prt _ [] = concatD []
  prt _ [x] = concatD [prt 0 x]
  prt _ (x:xs) = concatD [prt 0 x, doc (showString ","), prt 0 xs]

instance Print (AbsGengo.AddOp' a) where
  prt i = \case
    AbsGengo.Plus _ -> prPrec i 0 (concatD [doc (showString "+")])
    AbsGengo.Minus _ -> prPrec i 0 (concatD [doc (showString "-")])

instance Print (AbsGengo.MulOp' a) where
  prt i = \case
    AbsGengo.Times _ -> prPrec i 0 (concatD [doc (showString "*")])
    AbsGengo.Div _ -> prPrec i 0 (concatD [doc (showString "/")])
    AbsGengo.Mod _ -> prPrec i 0 (concatD [doc (showString "%")])

instance Print (AbsGengo.RelOp' a) where
  prt i = \case
    AbsGengo.LTH _ -> prPrec i 0 (concatD [doc (showString "<")])
    AbsGengo.LE _ -> prPrec i 0 (concatD [doc (showString "<=")])
    AbsGengo.GTH _ -> prPrec i 0 (concatD [doc (showString ">")])
    AbsGengo.GE _ -> prPrec i 0 (concatD [doc (showString ">=")])
    AbsGengo.EQU _ -> prPrec i 0 (concatD [doc (showString "==")])
    AbsGengo.NE _ -> prPrec i 0 (concatD [doc (showString "!=")])
