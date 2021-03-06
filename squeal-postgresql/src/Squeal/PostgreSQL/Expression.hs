{-|
Module: Squeal.PostgreSQL.Expression
Description: Squeal expressions
Copyright: (c) Eitan Chatav, 2019
Maintainer: eitan@morphism.tech
Stability: experimental

Squeal expressions are the atoms used to build statements.
-}

{-# LANGUAGE
    AllowAmbiguousTypes
  , ConstraintKinds
  , DeriveGeneric
  , FlexibleContexts
  , FlexibleInstances
  , FunctionalDependencies
  , GADTs
  , GeneralizedNewtypeDeriving
  , LambdaCase
  , MagicHash
  , OverloadedStrings
  , ScopedTypeVariables
  , StandaloneDeriving
  , TypeApplications
  , TypeFamilies
  , TypeInType
  , TypeOperators
  , UndecidableInstances
  , RankNTypes
#-}

module Squeal.PostgreSQL.Expression
  ( -- * Expression
    Expression (..)
  , Expr
    -- * Function
  , type (-->)
  , FunctionDB
  , unsafeFunction
  , function
  , unsafeLeftOp
  , unsafeRightOp
    -- * Operator
  , Operator
  , OperatorDB
  , unsafeBinaryOp
  , PGSubset (..)
  , PGIntersect (..)
    -- * Multivariable Function
  , FunctionVar
  , unsafeFunctionVar
  , type (--->)
  , FunctionNDB
  , unsafeFunctionN
  , functionN
    -- * Re-export
  , (&)
  ) where

import Control.Category
import Control.DeepSeq
import Data.ByteString (ByteString)
import Data.Function ((&))
import Data.Semigroup hiding (All)
import Data.String
import Generics.SOP hiding (All, from)
import GHC.OverloadedLabels
import GHC.TypeLits
import Numeric
import Prelude hiding (id, (.))

import qualified GHC.Generics as GHC

import Squeal.PostgreSQL.Alias
import Squeal.PostgreSQL.List
import Squeal.PostgreSQL.Render
import Squeal.PostgreSQL.Schema

-- $setup
-- >>> import Squeal.PostgreSQL

{-----------------------------------------
column expressions
-----------------------------------------}

{- | `Expression`s are used in a variety of contexts,
such as in the target `Squeal.PostgreSQL.Query.List` of the
`Squeal.PostgreSQL.Query.select` command,
as new column values in `Squeal.PostgreSQL.Manipulation.insertInto` or
`Squeal.PostgreSQL.Manipulation.update`,
or in search `Squeal.PostgreSQL.Expression.Logic.Condition`s
in a number of commands.

The expression syntax allows the calculation of
values from primitive expression using arithmetic, logical,
and other operations.

The type parameters of `Expression` are

* @lat :: @ `FromType`, the @from@ clauses of any lat queries in which
  the `Expression` is a correlated subquery expression;
* @with :: @ `FromType`, the `Squeal.PostgreSQL.Query.CommonTableExpression`s
  that are in scope for the `Expression`;
* @grp :: @ `Grouping`, the `Grouping` of the @from@ clause which may limit
  which columns may be referenced by alias;
* @db :: @ `SchemasType`, the schemas of your database that are in
  scope for the `Expression`;
* @from :: @ `FromType`, the @from@ clause which the `Expression` may use
  to reference columns by alias;
* @ty :: @ `NullType`, the type of the `Expression`.
-}
newtype Expression
  (lat :: FromType)
  (with :: FromType)
  (grp :: Grouping)
  (db :: SchemasType)
  (params :: [NullType])
  (from :: FromType)
  (ty :: NullType)
    = UnsafeExpression { renderExpression :: ByteString }
    deriving (GHC.Generic,Show,Eq,Ord,NFData)
instance RenderSQL (Expression lat with grp db params from ty) where
  renderSQL = renderExpression

-- | An `Expr` is a closed `Expression`.
-- It is a F@RankNType@ but don't be scared.
-- Think of it as an expression which sees no
-- namespaces, so you can't use parameters
-- or alias references. It can be used as
-- a simple piece of more complex `Expression`s.
type Expr x
  = forall lat with grp db params from
  . Expression lat with grp db params from x
    -- ^ cannot reference aliases

-- | A @RankNType@ for binary operators.
type Operator x1 x2 y
  =  forall lat with grp db params from
  .  Expression lat with grp db params from x1
     -- ^ left input
  -> Expression lat with grp db params from x2
     -- ^ right input
  -> Expression lat with grp db params from y
     -- ^ output

-- | Like `Operator` but depends on the schemas of the database
type OperatorDB db x1 x2 y
  =  forall lat with grp params from
  .  Expression lat with grp db params from x1
     -- ^ left input
  -> Expression lat with grp db params from x2
     -- ^ right input
  -> Expression lat with grp db params from y
     -- ^ output

-- | A @RankNType@ for functions with a single argument.
-- These could be either function calls or unary operators.
-- This is a subtype of the usual Haskell function type `Prelude.->`,
-- indeed a subcategory as it is closed under the usual
-- `Prelude..` and `Prelude.id`.
type (-->) x y
  =  forall lat with grp db params from
  .  Expression lat with grp db params from x
     -- ^ input
  -> Expression lat with grp db params from y
     -- ^ output

-- | Like `-->` but depends on the schemas of the database
type FunctionDB db x y
  =  forall lat with grp params from
  .  Expression lat with grp db params from x
     -- ^ input
  -> Expression lat with grp db params from y
     -- ^ output

{- | A @RankNType@ for functions with a fixed-length list of heterogeneous arguments.
Use the `*:` operator to end your argument lists, like so.

>>> printSQL (unsafeFunctionN "fun" (true :* false :* localTime *: true))
fun(TRUE, FALSE, LOCALTIME, TRUE)
-}
type (--->) xs y
  =  forall lat with grp db params from
  .  NP (Expression lat with grp db params from) xs
     -- ^ inputs
  -> Expression lat with grp db params from y
     -- ^ output

-- | Like `--->` but depends on the schemas of the database
type FunctionNDB db xs y
  =  forall lat with grp params from
  .  NP (Expression lat with grp db params from) xs
     -- ^ inputs
  -> Expression lat with grp db params from y
     -- ^ output

{- | A @RankNType@ for functions with a variable-length list of
homogeneous arguments and at least 1 more argument.
-}
type FunctionVar x0 x1 y
  =  forall lat with grp db params from
  .  [Expression lat with grp db params from x0]
     -- ^ inputs
  -> Expression lat with grp db params from x1
     -- ^ must have at least 1 input
  -> Expression lat with grp db params from y
     -- ^ output

{- | >>> printSQL (unsafeFunctionVar "greatest" [true, null_] false)
greatest(TRUE, NULL, FALSE)
-}
unsafeFunctionVar :: ByteString -> FunctionVar x0 x1 y
unsafeFunctionVar fun xs x = UnsafeExpression $ fun <> parenthesized
  (commaSeparated (renderSQL <$> xs) <> ", " <> renderSQL x)

instance (HasUnique tab (Join lat from) row, Has col row ty)
  => IsLabel col (Expression lat with 'Ungrouped db params from ty) where
    fromLabel = UnsafeExpression $ renderSQL (Alias @col)
instance (HasUnique tab (Join lat from) row, Has col row ty, tys ~ '[ty])
  => IsLabel col (NP (Expression lat with 'Ungrouped db params from) tys) where
    fromLabel = fromLabel @col :* Nil
instance (HasUnique tab (Join lat from) row, Has col row ty, column ~ (col ::: ty))
  => IsLabel col
    (Aliased (Expression lat with 'Ungrouped db params from) column) where
    fromLabel = fromLabel @col `As` Alias
instance (HasUnique tab (Join lat from) row, Has col row ty, columns ~ '[col ::: ty])
  => IsLabel col
    (NP (Aliased (Expression lat with 'Ungrouped db params from)) columns) where
    fromLabel = fromLabel @col :* Nil

instance (Has tab (Join lat from) row, Has col row ty)
  => IsQualified tab col (Expression lat with 'Ungrouped db params from ty) where
    tab ! col = UnsafeExpression $
      renderSQL tab <> "." <> renderSQL col
instance (Has tab (Join lat from) row, Has col row ty, tys ~ '[ty])
  => IsQualified tab col (NP (Expression lat with 'Ungrouped db params from) tys) where
    tab ! col = tab ! col :* Nil
instance (Has tab (Join lat from) row, Has col row ty, column ~ (col ::: ty))
  => IsQualified tab col
    (Aliased (Expression lat with 'Ungrouped db params from) column) where
    tab ! col = tab ! col `As` col
instance (Has tab (Join lat from) row, Has col row ty, columns ~ '[col ::: ty])
  => IsQualified tab col
    (NP (Aliased (Expression lat with 'Ungrouped db params from)) columns) where
    tab ! col = tab ! col :* Nil

instance
  ( HasUnique tab (Join lat from) row
  , Has col row ty
  , GroupedBy tab col bys
  ) => IsLabel col
    (Expression lat with ('Grouped bys) db params from ty) where
      fromLabel = UnsafeExpression $ renderSQL (Alias @col)
instance
  ( HasUnique tab (Join lat from) row
  , Has col row ty
  , GroupedBy tab col bys
  , tys ~ '[ty]
  ) => IsLabel col
    (NP (Expression lat with ('Grouped bys) db params from) tys) where
      fromLabel = fromLabel @col :* Nil
instance
  ( HasUnique tab (Join lat from) row
  , Has col row ty
  , GroupedBy tab col bys
  , column ~ (col ::: ty)
  ) => IsLabel col
    (Aliased (Expression lat with ('Grouped bys) db params from) column) where
      fromLabel = fromLabel @col `As` Alias
instance
  ( HasUnique tab (Join lat from) row
  , Has col row ty
  , GroupedBy tab col bys
  , columns ~ '[col ::: ty]
  ) => IsLabel col
    (NP (Aliased (Expression lat with ('Grouped bys) db params from)) columns) where
      fromLabel = fromLabel @col :* Nil

instance
  ( Has tab (Join lat from) row
  , Has col row ty
  , GroupedBy tab col bys
  ) => IsQualified tab col
    (Expression lat with ('Grouped bys) db params from ty) where
      tab ! col = UnsafeExpression $
        renderSQL tab <> "." <> renderSQL col
instance
  ( Has tab (Join lat from) row
  , Has col row ty
  , GroupedBy tab col bys
  , tys ~ '[ty]
  ) => IsQualified tab col
    (NP (Expression lat with ('Grouped bys) db params from) tys) where
      tab ! col = tab ! col :* Nil
instance
  ( Has tab (Join lat from) row
  , Has col row ty
  , GroupedBy tab col bys
  , column ~ (col ::: ty)
  ) => IsQualified tab col
    (Aliased (Expression lat with ('Grouped bys) db params from) column) where
      tab ! col = tab ! col `As` col
instance
  ( Has tab (Join lat from) row
  , Has col row ty
  , GroupedBy tab col bys
  , columns ~ '[col ::: ty]
  ) => IsQualified tab col
    (NP (Aliased (Expression lat with ('Grouped bys) db params from)) columns) where
      tab ! col = tab ! col :* Nil

instance (KnownSymbol label, label `In` labels) => IsPGlabel label
  (Expression lat with grp db params from (null ('PGenum labels))) where
  label = UnsafeExpression $ renderSQL (PGlabel @label)

-- | >>> printSQL $ unsafeBinaryOp "OR" true false
-- (TRUE OR FALSE)
unsafeBinaryOp :: ByteString -> Operator ty0 ty1 ty2
unsafeBinaryOp op x y = UnsafeExpression $ parenthesized $
  renderSQL x <+> op <+> renderSQL y

-- | >>> printSQL $ unsafeLeftOp "NOT" true
-- (NOT TRUE)
unsafeLeftOp :: ByteString -> x --> y
unsafeLeftOp op x = UnsafeExpression $ parenthesized $ op <+> renderSQL x

-- | >>> printSQL $ true & unsafeRightOp "IS NOT TRUE"
-- (TRUE IS NOT TRUE)
unsafeRightOp :: ByteString -> x --> y
unsafeRightOp op x = UnsafeExpression $ parenthesized $ renderSQL x <+> op

-- | >>> printSQL $ unsafeFunction "f" true
-- f(TRUE)
unsafeFunction :: ByteString -> x --> y
unsafeFunction fun x = UnsafeExpression $
  fun <> parenthesized (renderSQL x)

{- | Call a user defined function of a single variable

>>> type Fn = '[ 'Null 'PGint4] :=> 'Returns ('NotNull 'PGnumeric)
>>> type Schema = '["fn" ::: 'Function Fn]
>>> :{
let
  fn :: FunctionDB (Public Schema) ('Null 'PGint4) ('NotNull 'PGnumeric)
  fn = function #fn
in
  printSQL (fn 1)
:}
"fn"(1)
-}
function
  :: (Has sch db schema, Has fun schema ('Function ('[x] :=> 'Returns y)))
  => QualifiedAlias sch fun -- ^ function name
  -> FunctionDB db x y
function = unsafeFunction . renderSQL

-- | >>> printSQL $ unsafeFunctionN "f" (currentTime :* localTimestamp :* false *: literal 'a')
-- f(CURRENT_TIME, LOCALTIMESTAMP, FALSE, E'a')
unsafeFunctionN :: SListI xs => ByteString -> xs ---> y
unsafeFunctionN fun xs = UnsafeExpression $
  fun <> parenthesized (renderCommaSeparated renderSQL xs)

{- | Call a user defined multivariable function

>>> type Fn = '[ 'Null 'PGint4, 'Null 'PGbool] :=> 'Returns ('NotNull 'PGnumeric)
>>> type Schema = '["fn" ::: 'Function Fn]
>>> :{
let
  fn :: FunctionNDB (Public Schema) '[ 'Null 'PGint4, 'Null 'PGbool] ('NotNull 'PGnumeric)
  fn = functionN #fn
in
  printSQL (fn (1 *: true))
:}
"fn"(1, TRUE)
-}
functionN
  :: ( Has sch db schema
     , Has fun schema ('Function (xs :=> 'Returns y))
     , SListI xs )
  => QualifiedAlias sch fun -- ^ function alias
  -> FunctionNDB db xs y
functionN = unsafeFunctionN . renderSQL

instance ty `In` PGNum
  => Num (Expression lat with grp db params from (null ty)) where
    (+) = unsafeBinaryOp "+"
    (-) = unsafeBinaryOp "-"
    (*) = unsafeBinaryOp "*"
    abs = unsafeFunction "abs"
    signum = unsafeFunction "sign"
    fromInteger
      = UnsafeExpression
      . fromString
      . show

instance (ty `In` PGNum, ty `In` PGFloating) => Fractional
  (Expression lat with grp db params from (null ty)) where
    (/) = unsafeBinaryOp "/"
    fromRational
      = UnsafeExpression
      . fromString
      . ($ "")
      . showFFloat Nothing
      . fromRat @Double

instance (ty `In` PGNum, ty `In` PGFloating) => Floating
  (Expression lat with grp db params from (null ty)) where
    pi = UnsafeExpression "pi()"
    exp = unsafeFunction "exp"
    log = unsafeFunction "ln"
    sqrt = unsafeFunction "sqrt"
    b ** x = UnsafeExpression $
      "power(" <> renderSQL b <> ", " <> renderSQL x <> ")"
    logBase b y = log y / log b
    sin = unsafeFunction "sin"
    cos = unsafeFunction "cos"
    tan = unsafeFunction "tan"
    asin = unsafeFunction "asin"
    acos = unsafeFunction "acos"
    atan = unsafeFunction "atan"
    sinh x = (exp x - exp (-x)) / 2
    cosh x = (exp x + exp (-x)) / 2
    tanh x = sinh x / cosh x
    asinh x = log (x + sqrt (x*x + 1))
    acosh x = log (x + sqrt (x*x - 1))
    atanh x = log ((1 + x) / (1 - x)) / 2

-- | Contained by operators
class PGSubset ty where
  (@>) :: Operator (null0 ty) (null1 ty) ('Null 'PGbool)
  (@>) = unsafeBinaryOp "@>"
  (<@) :: Operator (null0 ty) (null1 ty) ('Null 'PGbool)
  (<@) = unsafeBinaryOp "<@"
instance PGSubset 'PGjsonb
instance PGSubset 'PGtsquery
instance PGSubset ('PGvararray ty)
instance PGSubset ('PGrange ty)

-- | Intersection operator
class PGIntersect ty where
  (@&&) :: Operator (null0 ty) (null1 ty) ('Null 'PGbool)
  (@&&) = unsafeBinaryOp "&&"
instance PGIntersect ('PGvararray ty)
instance PGIntersect ('PGrange ty)

instance IsString
  (Expression lat with grp db params from (null 'PGtext)) where
    fromString str = UnsafeExpression $
      "E\'" <> fromString (escape =<< str) <> "\'"
instance IsString
  (Expression lat with grp db params from (null 'PGtsvector)) where
    fromString str = UnsafeExpression . parenthesized . (<> " :: tsvector") $
      "E\'" <> fromString (escape =<< str) <> "\'"
instance IsString
  (Expression lat with grp db params from (null 'PGtsquery)) where
    fromString str = UnsafeExpression . parenthesized . (<> " :: tsquery") $
      "E\'" <> fromString (escape =<< str) <> "\'"

instance Semigroup
  (Expression lat with grp db params from (null ('PGvararray ty))) where
    (<>) = unsafeBinaryOp "||"
instance Semigroup
  (Expression lat with grp db params from (null 'PGjsonb)) where
    (<>) = unsafeBinaryOp "||"
instance Semigroup
  (Expression lat with grp db params from (null 'PGtext)) where
    (<>) = unsafeBinaryOp "||"
instance Semigroup
  (Expression lat with grp db params from (null 'PGtsvector)) where
    (<>) = unsafeBinaryOp "||"

instance Monoid
  (Expression lat with grp db params from (null 'PGtext)) where
    mempty = fromString ""
    mappend = (<>)
instance Monoid
  (Expression lat with grp db params from (null 'PGtsvector)) where
    mempty = fromString ""
    mappend = (<>)
