module FormatNix where

import Prelude

import Data.Array as Array
import Data.Foldable (class Foldable)
import Data.List (List(..), (:))
import Data.List as List
import Data.Maybe (Maybe(..))
import Data.Newtype (class Newtype)
import Data.String as String
import Data.Traversable (foldMap, intercalate)
import Motsunabe (Doc(..), pretty)
import Unsafe.Coerce (unsafeCoerce)

data Expr
  -- top level
  = Expression (Array Expr)
  -- i just want to print comments
  | Comment String
  -- <nixpkgs>
  | Spath String
  -- ../whatever.nix
  | Path String
  -- "hi"
  | StringValue String
  -- integer, e.g. 123
  | Integer String
  -- indented string
  | StringIndented String
  -- unary, e.g. !x, -a
  | Unary String Expr
  -- binary, e.g. a < b
  | Binary Expr String Expr
  -- Identifier
  | Identifier String
  -- function, input_expr: output_expr
  | Function Expr Expr
  -- set function, { formals }: output_expr
  | SetFunction Expr Expr
  -- the main thing, application of a function with its arg?
  | App Expr Expr
  -- let exprs in exprs
  | Let (Array Expr) (Array Expr)
  -- if cond_exprs then_exprs else_exprs
  | If Expr Expr Expr
  -- a set
  | AttrSet (Array Expr)
  -- a recursive attr set
  | RecAttrSet (Array Expr)
  -- parenthesized
  | Parens Expr
  -- a list
  | List (Array Expr)
  -- bind, e.g. owner = 1;
  | Bind Expr Expr
  -- attrpath, only contains Identifier? e.g. owner of owner = 1;
  | AttrPath String
  -- inherit
  | Inherit (Array Expr)
  -- with (thing); expr
  | With Expr Expr
  -- attributes for inherit?
  | Attrs (Array Expr)
  -- as in `set.attr`, Select expr selector_expr
  | Select Expr Expr
  -- set fn args, e.g. inside of braces { pkgs ? import <nixpkgs> {} }:
  | Formals (Array Expr)
  -- ellipses, they show up in formals
  | Ellipses
  -- set fn arg with an identifier, where it may or may not have a default value expr
  | Formal Expr (Maybe Expr)
  -- Uri
  | Uri String
  -- unknown node type, with the type string and text contents
  | Unknown String String
derive instance eqExpr :: Eq Expr

-- | Node from tree-sitter
foreign import data Node :: Type

children :: Node -> Array Node
children tn = tn'.children
  where tn' = unsafeCoerce tn :: { children :: Array Node }

-- | Filter for named children
namedChildren :: Node -> Array Node
namedChildren = Array.filter isNamed <<< children

-- | Is a given Node Real or is it fake?
isNamed :: Node -> Boolean
isNamed tn = tn'.isNamed
  where tn' = unsafeCoerce tn :: { isNamed :: Boolean }

text :: Node -> String
text tn = tn'.text
  where tn' = unsafeCoerce tn :: { text :: String }

newtype TypeString = TypeString String
derive instance newtypeTypeString :: Newtype TypeString _
derive newtype instance eqTypeString :: Eq TypeString

type_ :: Node -> TypeString
type_ tn = tn'."type"
  where tn' = unsafeCoerce tn :: { "type" :: TypeString }

foreign import data TreeSitterLanguage :: Type
foreign import nixLanguage :: TreeSitterLanguage

foreign import mkParser :: TreeSitterLanguage -> TreeSitterParser

foreign import data TreeSitterParser :: Type

parse :: TreeSitterParser -> String -> Tree
parse parser contents = parser'.parse contents
  where parser' = unsafeCoerce parser :: { parse :: String -> Tree }

foreign import data Tree :: Type

rootNode :: Tree -> Node
rootNode tree = tree'.rootNode
  where tree' = unsafeCoerce tree :: { rootNode :: Node }

nodeToString :: Node -> String
nodeToString node = node'.toString unit
  where node' = unsafeCoerce node :: { toString :: Unit -> String }

readNode :: Node -> Expr
readNode n = readNode' (type_ n) n

readChildren :: (Array Expr -> Expr) -> Node -> Expr
readChildren = \ctr n -> ctr $ readNode <$> namedChildren n

readNode' :: TypeString -> Node -> Expr
readNode' (TypeString "comment") n = Comment (text n)
readNode' (TypeString "function") n
  | (input : output : Nil ) <- List.fromFoldable (readNode <$> namedChildren n)
    = case input of
        Formals _ -> SetFunction input output
        _ -> Function input output
  | otherwise = Unknown "function variation" (text n)
readNode' (TypeString "formals") n = readChildren Formals n
readNode' (TypeString "formal") n
  | children' <- List.fromFoldable (readNode <$> namedChildren n)
  = case children' of
      identifier : Nil -> Formal identifier Nothing
      identifier : default : Nil -> Formal identifier (Just default)
      _ -> Unknown "formal varigation" (text n)
readNode' (TypeString "attrset") n =  AttrSet $ readNode <$> namedChildren n
readNode' (TypeString "list") n =  List $ readNode <$> namedChildren n
readNode' (TypeString "rec_attrset") n =  RecAttrSet $ readNode <$> namedChildren n
readNode' (TypeString "attrs") n = readChildren Attrs n
readNode' (TypeString "app") n
  | (fn : arg : Nil ) <- List.fromFoldable (readNode <$> namedChildren n)
    = App fn arg
  | otherwise = Unknown "App variation" (text n)
readNode' (TypeString "if") n
  | (cond : then_ : else_ : Nil ) <- List.fromFoldable (namedChildren n)
    = If (readNode cond) (readNode then_) (readNode else_)
  | otherwise = Unknown "if variation" (text n)
readNode' (TypeString "let") n
  -- take all anonymous nodes minus first (let)
  | children' <- Array.drop 1 $ children n
  -- split the array by "in"
  , Just inIdx <- Array.findIndex (\x -> type_ x == TypeString "in") children'
  , binds <- readNode <$> Array.take inIdx children'
  , exprs <- readNode <$> Array.drop (inIdx + 1) children'
    = Let binds exprs
  | otherwise = Unknown "let variation" (text n)
readNode' (TypeString "parenthesized") n
  | expr : Nil <- List.fromFoldable (readNode <$> namedChildren n)
    = Parens expr
  | otherwise = Unknown "parenthesized variation" (text n)
readNode' (TypeString "bind") n
  | children' <- namedChildren n
  , name : value : Nil <- List.fromFoldable (readNode <$> namedChildren n)
    = Bind name value
  | otherwise = Unknown "Bind variation" (text n)
readNode' (TypeString "inherit") n = Inherit $ readNode <$> namedChildren n
readNode' (TypeString "with") n
  | children' <- namedChildren n
  , name : value : Nil <- List.fromFoldable (readNode <$> namedChildren n)
    = With name value
  | otherwise = Unknown "With variation" (text n)
readNode' (TypeString "select") n
  | value : selector : Nil <- List.fromFoldable (readNode <$> namedChildren n)
    = Select value selector
  | otherwise = Unknown "Select variation" (text n)
readNode' (TypeString "unary") n
  | children' <- children n
  , sign : expr : Nil <- List.fromFoldable children'
    = Unary (text sign) (readNode expr)
  | otherwise = Unknown "Unary variation" (text n)
readNode' (TypeString "binary") n
  | children' <- children n
  , x : sign : y : Nil <- List.fromFoldable children'
    = Binary (readNode x) (text sign) (readNode y)
  | otherwise = Unknown "Binary variation" (text n)
readNode' (TypeString "ellipses") n = Ellipses
readNode' (TypeString "attrpath") n = AttrPath (text n)
readNode' (TypeString "identifier") n = Identifier (text n)
readNode' (TypeString "spath") n = Spath (text n)
readNode' (TypeString "path") n = Path (text n)
readNode' (TypeString "string") n = StringValue (text n)
readNode' (TypeString "integer") n = Integer (text n)
readNode' (TypeString "uri") n = Uri (text n)
readNode' (TypeString "indented_string") n = StringIndented (text n)
readNode' (TypeString unknown) n = Unknown unknown (text n)

-- extra contextual information for generating Doc from Expr
type Context =
  -- are we inside of a fetch application? i.e. we don't need double newlines for fetch properties
  { fetch :: Boolean
  }

defaultContext :: Context
defaultContext =
  { fetch: false
  }

expr2Doc :: Context -> Expr -> Doc
expr2Doc ctx Ellipses = DText "..."
expr2Doc ctx (Comment str) = DText str
expr2Doc ctx (Identifier str) = DText str
expr2Doc ctx (Spath str) = DText str
expr2Doc ctx (Path str) = DText str
expr2Doc ctx (Integer str) = DText str
expr2Doc ctx (AttrPath str) = DText str
expr2Doc ctx (StringValue str) = DText str
expr2Doc ctx (StringIndented str) = DText str
expr2Doc ctx (Unknown tag str) = DText $ "Unknown " <> tag <> " " <> str
expr2Doc ctx (Unary sign expr) = DText sign <> expr2Doc ctx expr
expr2Doc ctx (Binary x sign y) = expr2Doc ctx x <> DText (" " <> sign <> " ") <> expr2Doc ctx y
expr2Doc ctx (Expression exprs) = dlines $ expr2Doc ctx <$> exprs
expr2Doc ctx (List exprs) = left <> choices <> right
  where
    inners = expr2Doc ctx <$> exprs
    left = DText "["
    right = DText "]"
    choices = DAlt oneLine asLines
    oneLine = dwords inners <> DText " "
    asLines = (DNest 1 (dlines inners)) <> DLine
expr2Doc ctx (Attrs exprs)
  | docs <- expr2Doc ctx <$> exprs = DAlt
  (intercalate (DText " ") docs)
  (DNest 1 (dlines docs))
expr2Doc ctx (AttrSet exprs) = if Array.null exprs
  then DText "{}"
  else do
    let dlinesN = if ctx.fetch then dlines else dlines2
    let left = DText "{"
    let right = DLine <> DText "}"
    let inners = dlinesN $ expr2Doc ctx <$> exprs
    left <> DNest 1 inners <> right
expr2Doc ctx (RecAttrSet exprs) = DText "rec " <> expr2Doc ctx (AttrSet exprs)
expr2Doc ctx (SetFunction input output) =
  DText "{" <> input_ <> DText "}:" <> DLine <> DLine <> output_
  where
    input_ = expr2Doc ctx input
    output_ = expr2Doc ctx output
expr2Doc ctx (Function input output) = input_ <> DText ": " <> output_
  where
    input_ = expr2Doc ctx input
    output_ = expr2Doc ctx output
expr2Doc ctx (Let binds expr) = let_ <> binds' <> in_ <> expr'
  where
    let_ = DText "let"
    in_ = DLine <> DLine <> DText "in "
    binds' = DNest 1 $ dlines2 $ expr2Doc ctx <$> binds
    expr'
      | Array.length expr == 1
      , Just head <- Array.head expr = expr2Doc ctx head
      | otherwise = DNest 1 $ dlines2 $ expr2Doc ctx <$> expr
expr2Doc ctx (If cond first second) = if_ <> then_ <> else_
  where
    if_ = DText "if " <> expr2Doc ctx cond
    then_ = DNest 1 $ DLine <> (DText "then ") <> expr2Doc ctx first
    else_ = DNest 1 $ DLine <> (DText "else ") <> expr2Doc ctx second
expr2Doc ctx (Parens expr) = DText "(" <> expr2Doc ctx expr <> DText ")"
expr2Doc ctx (Bind name value) =
  expr2Doc ctx name <> DText " = " <> expr2Doc ctx value <> DText ";"
expr2Doc ctx (Inherit exprs) = DText "inherit" <> inner <> DText ";"
  where
    inner = dwords $ expr2Doc ctx <$> exprs
expr2Doc ctx (With name value) = DText "with " <> expr2Doc ctx name <> DText "; " <> expr2Doc ctx value
expr2Doc ctx (App fn arg) = expr2Doc ctx fn <> DText " " <> expr2Doc newCtx arg
  where
    newCtx = if containsFetch fn
      then ctx { fetch = true }
      else ctx
expr2Doc ctx (Formals exprs) = DAlt oneLine lines
  where
    exprs' = expr2Doc ctx <$> exprs
    oneLine = DText " " <> intercalate (DText ", ") exprs' <> DText " "
    lines = DNest 1 (DLine <> intercalate (DText "," <> DLine) exprs') <> DLine
expr2Doc ctx (Formal identifier Nothing) = expr2Doc ctx identifier
expr2Doc ctx (Formal identifier (Just value)) = expr2Doc ctx identifier <> DText " ? " <> expr2Doc ctx value
expr2Doc ctx (Select value selector) = expr2Doc ctx value <> DText "." <> expr2Doc ctx selector
expr2Doc ctx (Uri str) = DText str

containsFetch :: Expr -> Boolean
containsFetch (Identifier x) = String.contains (String.Pattern "fetch") x
containsFetch (AttrPath x) = String.contains (String.Pattern "fetch") x
containsFetch (Select _ x) = containsFetch x
containsFetch _ = false

dwords :: forall f. Foldable f => f Doc -> Doc
dwords xs = foldMap (\x -> DText " " <> x) xs

dlines :: forall f. Foldable f => f Doc -> Doc
dlines xs = foldMap (\x -> DLine <> x) xs

dlines2 :: forall f. Foldable f => f Doc -> Doc
dlines2 xs = DLine <> intercalate (DLine <> DLine) xs

printExpr :: Expr -> String
printExpr = pretty 80 <<< expr2Doc defaultContext
