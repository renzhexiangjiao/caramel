open Sexplib.Std

module Error = struct
  type t =
    | End_of_file
    | Expected_expression of Span.t
    | Expected_type_expression of Span.t
    | Expected_name of Span.t
    | Expected_symbol of {
        expected : [ `One_of of Token.t list | `Exact of Token.t | `Unsure ];
        found : Span.t;
      }
    | Unexpected_token of Span.t
    | Invalid_quotation of Span.t
  [@@deriving sexp]

  let pp ppf error =
    let sexp = sexp_of_t error in
    Format.fprintf ppf "%a" (Sexplib.Sexp.pp_hum_indent 2) sexp

  exception Parse_error of t

  let err e = raise (Parse_error e)

  let expected_symbol ~sym ~found =
    err (Expected_symbol { expected = sym; found })

  let expected_name span = err (Expected_name span)

  let unexpected_token span = expected_symbol ~sym:`Unsure ~found:span

  let expected_expression span = err (Expected_expression span)

  let expected_type_expression span = err (Expected_type_expression span)

  let quote_expects_structure_item_or_expression span =
    err (Invalid_quotation span)
end

type t = {
  mutable token_provider : Token_provider.t;
  mutable last_span : Span.t;
  mutable curr_span : Span.t;
}
[@@deriving sexp]

(*** Parsing actions ***********************************************************)

let next t =
  match Token_provider.next t.token_provider with
  | Ok span ->
      t.last_span <- t.curr_span;
      t.curr_span <- span;
      (* Logs.debug (fun f -> f "token: %a" Token.pp t.curr_span.token); *)
      ()
  | Error (`Lexer_error err) -> raise (Lexer.Lexer_error err)

let peek t =
  match Token_provider.peek t.token_provider with
  | Ok span -> span
  | Error (`Lexer_error err) -> raise (Lexer.Lexer_error err)

let expect token t =
  if t.curr_span.token = token then next t
  else Error.expected_symbol ~sym:(`Exact token) ~found:t.curr_span

(*** Combinators ***************************************************************)

let sep_by sep parser t =
  let rec collect nodes =
    match parser t with
    | exception _ -> nodes
    | node ->
        let nodes = node :: nodes in
        if t.curr_span.token = sep then (
          next t;
          collect nodes)
        else nodes
  in
  List.rev (collect [])

let many parser t =
  let rec collect nodes =
    match parser t with exception _ -> nodes | node -> collect (node :: nodes)
  in
  List.rev (collect [])

(*** Parsers *******************************************************************)

let parse_name t =
  match t.curr_span.token with
  | Token.Id path ->
      next t;
      Some (Parsetree_helper.id path)
  | Token.Parens_left ->
      next t;
      if Token.is_op t.curr_span.token then (
        let str = Token.to_string t.curr_span.token in
        next t;
        expect Token.Parens_right t;
        Some (Parsetree_helper.id str))
      else None
  | _ -> None

let parse_op t =
  let op = Parsetree_helper.id (Token.to_string t.curr_span.token) in
  next t;
  op

let parse_visibility t =
  match t.curr_span.token with
  | Token.Pub ->
      next t;
      Parsetree_helper.Visibility.pub
  | _ -> Parsetree_helper.Visibility.priv

(*

*)

let parse_annotations_field t =
  let name =
    match parse_name t with
    | Some name -> name
    | None -> Error.expected_name t.curr_span
  in
  let value =
    match t.curr_span.token with
    | Token.Equal -> (
        next t;
        match t.curr_span.token with
        | Token.Id id ->
            next t;
            Some (Parsetree_helper.Expr.var (Parsetree_helper.id id))
        | Token.String str ->
            next t;
            Some (Parsetree_helper.Expr.lit_str str)
        | _ ->
            Error.expected_symbol
              ~sym:(`One_of [ Token.Id "some_id"; Token.String "some_string" ])
              ~found:t.curr_span)
    | _ -> None
  in
  Parsetree_helper.Annot.field ~name ~value

let parse_annotation t =
  match t.curr_span.token with
  | Token.At ->
      next t;
      let name =
        match parse_name t with
        | Some id -> id
        | None -> Error.expected_name t.curr_span
      in

      let desc =
        match t.curr_span.token with
        | Token.Parens_left ->
            next t;
            let fields = sep_by Token.Comma parse_annotations_field t in
            expect Token.Parens_right t;
            Some (Parsetree_helper.Annot.map ~fields)
        | _ -> None
      in

      Some (Parsetree_helper.Annot.mk ~name ~desc)
  | _ -> None

let parse_annotations t =
  let rec collect_annotations acc =
    match parse_annotation t with
    | Some annot -> collect_annotations (annot :: acc)
    | None -> acc
  in
  List.rev (collect_annotations [])

(*

*)

let rec parse_type_expr t =
  let parse_one t =
    match t.curr_span.token with
    | Token.Type_var name ->
        next t;
        Parsetree_helper.Typ.var name
    | Token.Parens_left ->
        next t;
        let parts = sep_by Token.Comma parse_type_expr t in
        expect Parens_right t;
        Parsetree_helper.Typ.tuple ~parts
    | Token.Id path -> (
        next t;
        let id = Parsetree_helper.id path in
        match parse_type_expr_args t with
        | [] -> Parsetree_helper.Typ.id id
        | args -> Parsetree_helper.Typ.apply ~id ~args)
    | _ -> Error.expected_symbol ~sym:(`One_of []) ~found:t.curr_span
  in

  let type_exprs = sep_by Token.Arrow parse_one t in
  let rec to_arrow exprs =
    match exprs with
    | [] -> Error.expected_type_expression t.curr_span
    | [ t ] -> t
    | t :: ts -> Parsetree_helper.Typ.arrow t (to_arrow ts)
  in
  to_arrow type_exprs

and parse_type_expr_args t =
  match t.curr_span.token with
  | Token.Lesser_than ->
      next t;
      let args = sep_by Token.Comma parse_type_expr t in
      expect Token.Greater_than t;
      args
  | _ -> []

let parse_type_decl_record_field t =
  let annot = parse_annotations t in
  let name =
    match parse_name t with
    | Some name -> name
    | None -> Error.expected_name t.curr_span
  in
  expect Token.Colon t;
  Parsetree_helper.Type.label_decl ~name ~type_:(parse_type_expr t) ~annot

let parse_type_decl_label_decls t =
  expect Token.Brace_left t;
  let fields = sep_by Token.Comma parse_type_decl_record_field t in
  expect Token.Brace_right t;
  fields

let parse_type_decl_variant_constructor t =
  let annot = parse_annotations t in
  let name =
    match parse_name t with
    | Some name -> name
    | None ->
        Error.expected_symbol
          ~sym:(`One_of [ Token.Id "A_constructor" ])
          ~found:t.curr_span
  in
  let args =
    match t.curr_span.token with
    | Token.Brace_left ->
        let labels = parse_type_decl_label_decls t in
        Parsetree_helper.Type.variant_record_args ~labels
    | Token.Parens_left ->
        next t;
        let parts = sep_by Token.Comma parse_type_expr t in
        expect Token.Parens_right t;
        Parsetree_helper.Type.variant_tuple_args ~parts
    | _ -> Parsetree_helper.Type.variant_tuple_args ~parts:[]
  in
  Parsetree_helper.Type.variant_constructor ~name ~args ~annot

let parse_type_decl_variant t =
  expect Token.Pipe t;
  let constructors = sep_by Token.Pipe parse_type_decl_variant_constructor t in
  Parsetree_helper.Type.variant ~constructors

let parse_type_decl_record t =
  let labels = parse_type_decl_label_decls t in
  Parsetree_helper.Type.record ~labels

let parse_type_decl_tuple t =
  expect Token.Parens_left t;
  let parts = sep_by Token.Comma parse_type_expr t in
  expect Token.Parens_right t;
  Parsetree_helper.Type.alias (Parsetree_helper.Typ.tuple ~parts)

let parse_type_decl_args t =
  let parse_arg t =
    match t.curr_span.token with
    | Token.Type_var s ->
        next t;
        s
    | _ ->
        Error.expected_symbol ~sym:(`Exact (Token.Type_var "a"))
          ~found:t.curr_span
  in

  match t.curr_span.token with
  | Token.Lesser_than ->
      next t;
      let args = sep_by Token.Comma parse_arg t in
      expect Token.Greater_than t;
      args
  | _ -> []

let parse_type_decl_alias id t =
  let name = Parsetree_helper.id id in
  next t;
  Parsetree_helper.Type.alias (Parsetree_helper.Typ.id name)

let parse_type_decl t ~annot =
  expect Token.Type t;
  let name =
    match parse_name t with
    | Some name -> name
    | None -> Error.expected_name t.curr_span
  in

  let args = parse_type_decl_args t in

  let desc =
    match t.curr_span.token with
    | Token.Equal -> (
        next t;
        match t.curr_span.token with
        | Token.Id id -> parse_type_decl_alias id t
        | Token.Pipe -> parse_type_decl_variant t
        | Token.Brace_left -> parse_type_decl_record t
        | Token.Parens_left -> parse_type_decl_tuple t
        | _ ->
            Error.expected_symbol
              ~sym:(`One_of [ Token.Pipe; Token.Brace_left ])
              ~found:t.curr_span)
    | _ -> Parsetree_helper.Type.abstract
  in
  Parsetree_helper.Type.mk ~name ~args ~desc ~annot

(*

  Parse patterns:

  * Binding
  * Literals
    * Strings
    * Atoms
    * Numbers
    * Tuples
    * Lists
  * Records
  * Variants

*)
let rec parse_pattern t =
  match t.curr_span.token with
  | Token.Any ->
      next t;
      Parsetree_helper.Pat.any
  | Token.Integer int ->
      next t;
      Parsetree_helper.Pat.lit_int int
  | Token.String str ->
      next t;
      Parsetree_helper.Pat.lit_str str
  | Token.Atom atom ->
      next t;
      Parsetree_helper.Pat.lit_atom atom
  | Token.Id name -> (
      next t;
      let id = Parsetree_helper.id name in
      match Parsetree_helper.id_kind id with
      | `constructor -> (
          match t.curr_span.token with
          | Token.Any ->
              next t;
              Parsetree_helper.Pat.any
          | Token.Brace_left ->
              parse_pattern_variant_constructor_record ~name:id t
          | Token.Parens_left ->
              parse_pattern_variant_constructor_tuple ~name:id t
          | _ -> Parsetree_helper.Pat.constructor_tuple ~name:id ~parts:[])
      | `value -> Parsetree_helper.Pat.bind id
      | `field_access _ ->
          Error.expected_symbol
            ~sym:(`One_of [ Token.Bracket_left; Token.Parens_left ])
            ~found:t.curr_span)
  | Token.Parens_left -> parse_pattern_tuple t
  | Token.Bracket_left -> parse_pattern_list t
  | _ -> Error.expected_symbol ~sym:(`Exact Token.Pipe) ~found:t.curr_span

and parse_pattern_tuple t =
  expect Token.Parens_left t;
  let parts = sep_by Token.Comma parse_pattern t in
  expect Token.Parens_right t;
  Parsetree_helper.Pat.tuple ~parts

(*
  Parse List patternessions:

  Empty list: [] -> Nil
  List: [a, b, c] -> [a | [ b | [ c | [] ] ] ]
  Cons: [a, ...b] -> [a | b]

*)
and parse_pattern_list t =
  expect Token.Bracket_left t;
  let init = sep_by Token.Comma parse_pattern t in

  let last =
    match t.curr_span.token with
    | Token.Bracket_right -> Parsetree_helper.Pat.nil
    | Token.Dot_dot_dot ->
        next t;
        parse_pattern t
    | _ ->
        Error.expected_symbol
          ~sym:(`One_of [ Token.Comma; Token.Bracket_right ])
          ~found:t.curr_span
  in

  let rec make_list init last =
    match init with
    | [] -> Parsetree_helper.Pat.nil
    | [ head ] -> Parsetree_helper.Pat.list ~head ~tail:last
    | head :: xs -> Parsetree_helper.Pat.list ~head ~tail:(make_list xs last)
  in

  expect Token.Bracket_right t;

  make_list init last

and parse_pattern_record_field t =
  let name =
    match parse_name t with
    | Some name -> name
    | None ->
        Error.expected_symbol ~sym:(`Exact (Token.Id "field_name"))
          ~found:t.curr_span
  in
  let pattern =
    match t.curr_span.token with
    | Token.Colon ->
        next t;
        parse_pattern t
    | _ -> Parsetree_helper.Pat.bind name
  in
  Parsetree_helper.Pat.field ~name ~pattern

and parse_pattern_variant_constructor_tuple ~name t =
  expect Token.Parens_left t;
  let parts = sep_by Token.Comma parse_pattern t in
  expect Token.Parens_right t;
  Parsetree_helper.Pat.constructor_tuple ~name ~parts

and parse_pattern_variant_constructor_record ~name t =
  expect Token.Brace_left t;
  let fields = sep_by Token.Comma parse_pattern_record_field t in
  let exhaustive =
    match t.curr_span.token with
    | Token.Any ->
        next t;
        Parsetree.Partial
    | _ -> Parsetree.Exhaustive
  in
  expect Token.Brace_right t;
  Parsetree_helper.Pat.constructor_record ~name ~fields ~exhaustive

(*

  Parse expressions:

  * Variables
  * Literals
    * Strings
    * Atoms
    * Numbers
    * Tuples
    * Lists
  * Records
  * Variants
  * Function calls

*)

let rec parse_one t =
  let expr =
    match t.curr_span.token with
    | Token.Let -> parse_expr_let t
    | Token.Parens_left -> parse_expr_tuple t
    | Token.Bracket_left -> parse_expr_list t
    | Token.Brace_left -> parse_expr_record t
    | Token.Open -> parse_expr_open t
    | Token.Id name -> (
        next t;
        let id = Parsetree_helper.id name in
        let name = Parsetree_helper.Expr.var id in
        match Parsetree_helper.id_kind id with
        | `field_access (id, field, rest) ->
            Parsetree_helper.Expr.parse_field_access id field rest
        | `constructor -> (
            match t.curr_span.token with
            | Token.Brace_left ->
                parse_expr_variant_constructor_record ~name:id t
            | Token.Parens_left ->
                parse_expr_variant_constructor_tuple ~name:id t
            | _ -> Parsetree_helper.Expr.constructor_tuple ~name:id ~parts:[])
        | `value -> (
            match t.curr_span.token with
            | Token.Parens_left -> parse_expr_call ~name t
            | _ -> name))
    | Token.Integer int ->
        next t;
        Parsetree_helper.Expr.lit_int int
    | Token.Atom name ->
        next t;
        Parsetree_helper.Expr.lit_atom name
    | Token.String str ->
        next t;
        Parsetree_helper.Expr.lit_str str
    | Token.Match -> parse_expr_match t
    | Token.Quote -> parse_expr_quote t
    | _ ->
        Error.expected_symbol
          ~sym:
            (`One_of
              [
                Token.Atom "atom";
                Token.Id "id";
                Token.String "string";
                Token.Parens_left;
                Token.Bracket_left;
                Token.Match;
                Token.Quote;
                Token.Unquote;
                Token.Open;
              ])
          ~found:t.curr_span
  in
  parse_expr_binary_op expr t

and parse_expression t =
  let expr = parse_one t in
  let expr = parse_expr_seq expr t in
  expr

and parse_expr_seq expr t =
  match t.curr_span.token with
  | Token.Semicolon ->
      next t;
      Parsetree_helper.Expr.seq expr (parse_expression t)
  | _ -> expr

and parse_expr_binary_op fst t =
  if Token.is_op t.curr_span.token then
    let raw_op = parse_op t in
    let snd = parse_one t in
    let name = Parsetree_helper.Expr.var raw_op in
    Parsetree_helper.Expr.call ~name ~args:[ fst; snd ]
  else fst

and parse_expr_let t =
  expect Token.Let t;
  let pat = parse_pattern t in
  expect Token.Equal t;
  let body = parse_one t in
  match t.curr_span.token with
  | Token.Semicolon ->
      next t;
      let expr = parse_expression t in
      Parsetree_helper.Expr.let_ ~pat ~body ~expr
  | _ -> body

and parse_expr_call ~name t =
  expect Token.Parens_left t;
  let args = sep_by Token.Comma parse_expression t in

  expect Token.Parens_right t;
  Parsetree_helper.Expr.call ~name ~args

and parse_expr_quote t =
  expect Token.Quote t;
  expect Token.Brace_left t;

  let parse_unquote t =
    expect Token.Unquote t;
    expect Token.Parens_left t;
    let expr = parse_expression t in
    expect Token.Parens_right t;
    Parsetree_helper.Macro.unquote ~expr
  in

  let parse_unquote_splicing t =
    expect Token.Unquote_splicing t;
    expect Token.Parens_left t;
    let expr = parse_expression t in
    expect Token.Parens_right t;
    Parsetree_helper.Macro.unquote_splicing ~expr
  in

  let quote =
    let rec collect_tokens ~level tokens acc =
      let token = t.curr_span.token in
      match token with
      | Token.Brace_right when level = 0 ->
          let sym = Parsetree_helper.Macro.quote ~tokens:(List.rev tokens) in
          List.rev (sym :: acc)
      | Token.Brace_right ->
          next t;
          collect_tokens ~level:(level - 1) (token :: tokens) acc
      | Token.Brace_left ->
          next t;
          collect_tokens ~level:(level + 1) (token :: tokens) acc
      | Token.Unquote ->
          let sym = Parsetree_helper.Macro.quote ~tokens:(List.rev tokens) in
          let unquote = parse_unquote t in
          collect_tokens ~level [] (unquote :: sym :: acc)
      | Token.Unquote_splicing ->
          let sym = Parsetree_helper.Macro.quote ~tokens:(List.rev tokens) in
          let unquote = parse_unquote_splicing t in
          collect_tokens ~level [] (unquote :: sym :: acc)
      | _ ->
          next t;
          collect_tokens ~level (token :: tokens) acc
    in
    collect_tokens ~level:0 [] []
  in
  expect Token.Brace_right t;
  Parsetree_helper.Expr.quote ~quote

and parse_expr_tuple t =
  expect Token.Parens_left t;
  let parts = sep_by Token.Comma parse_expression t in
  expect Token.Parens_right t;
  Parsetree_helper.Expr.tuple ~parts

and parse_expr_record_field t =
  let name =
    match parse_name t with
    | Some name -> name
    | None -> Error.expected_name t.curr_span
  in
  expect Token.Colon t;
  let expr = parse_expression t in
  Parsetree_helper.Expr.field ~name ~expr

and parse_expr_record t =
  expect Token.Brace_left t;
  let fields = sep_by Token.Comma parse_expr_record_field t in
  expect Token.Brace_right t;
  Parsetree_helper.Expr.record ~fields

and parse_expr_variant_constructor_tuple ~name t =
  expect Token.Parens_left t;
  let parts = sep_by Token.Comma parse_expression t in
  expect Token.Parens_right t;
  Parsetree_helper.Expr.constructor_tuple ~name ~parts

and parse_expr_variant_constructor_record ~name t =
  expect Token.Brace_left t;
  let fields = sep_by Token.Comma parse_expr_record_field t in
  expect Token.Brace_right t;
  Parsetree_helper.Expr.constructor_record ~name ~fields

and parse_expr_open t =
  expect Token.Open t;
  let mod_name =
    match parse_name t with
    | Some name -> name
    | None ->
        Error.expected_symbol ~sym:(`Exact (Token.Id "Module_name"))
          ~found:t.curr_span
  in
  expect Token.Semicolon t;
  Parsetree_helper.Expr.open_ ~mod_name ~expr:(parse_expression t)

(*
  Parse List expressions:

  Empty list: [] -> Nil
  List: [a, b, c] -> [a | [ b | [ c | [] ] ] ]
  Cons: [a, ...b] -> [a | b]

*)
and parse_expr_list t =
  expect Token.Bracket_left t;
  let init = sep_by Token.Comma parse_expression t in

  let last =
    match t.curr_span.token with
    | Token.Bracket_right -> Parsetree_helper.Expr.nil
    | Token.Dot_dot_dot ->
        next t;
        parse_expression t
    | _ ->
        Error.expected_symbol
          ~sym:(`One_of [ Token.Dot_dot_dot; Token.Bracket_right ])
          ~found:t.curr_span
  in

  let rec make_list init last =
    match init with
    | [] -> Parsetree_helper.Expr.nil
    | [ head ] -> Parsetree_helper.Expr.list ~head ~tail:last
    | head :: xs -> Parsetree_helper.Expr.list ~head ~tail:(make_list xs last)
  in

  expect Token.Bracket_right t;

  make_list init last

and parse_expr_match t =
  expect Token.Match t;
  let expr = parse_expression t in
  expect Token.Brace_left t;
  expect Token.Pipe t;
  let cases = sep_by Token.Pipe parse_case_branch t in
  expect Token.Brace_right t;
  Parsetree_helper.Expr.match_ ~expr ~cases

and parse_case_branch t =
  let lhs = parse_pattern t in
  expect Token.Arrow t;
  let rhs = parse_expression t in
  Parsetree_helper.Expr.case ~lhs ~rhs

and parse_fun_arg t = (Parsetree.No_label, parse_pattern t)

and parse_fun_decl t ~annot ~visibility =
  let name =
    match parse_name t with
    | Some name -> name
    | None -> Error.expected_name t.curr_span
  in
  expect Token.Parens_left t;
  let args = sep_by Token.Comma parse_fun_arg t in
  expect Token.Parens_right t;
  expect Token.Brace_left t;
  let body = parse_expression t in
  expect Token.Brace_right t;
  Parsetree_helper.Fun_decl.mk ~name ~args ~visibility ~annot ~body

and parse_extern t ~annot ~visibility =
  expect Token.External t;
  let name =
    match parse_name t with
    | Some name -> name
    | None -> Error.expected_name t.curr_span
  in
  expect Token.Colon t;
  let type_sig = parse_type_expr t in
  expect Token.Equal t;
  let symbol =
    match t.curr_span.token with
    | Token.String str ->
        next t;
        str
    | _ ->
        Error.expected_symbol ~sym:(`Exact (Token.String "a string"))
          ~found:t.curr_span
  in
  Parsetree_helper.Ext.mk ~name ~type_sig ~symbol ~annot ~visibility

(*

  Parse blocks of code that are surrounded by braces.

  ```
  { expr? }
  ```

*)
and parse_structure_item t =
  let annot = parse_annotations t in

  let visibility = parse_visibility t in

  let node =
    match t.curr_span.token with
    | Token.Comment c -> Parsetree_helper.Str.comment c
    | Token.Open -> Parsetree_helper.Str.mod_expr (parse_module_open t)
    | Token.Module ->
        Parsetree_helper.Str.mod_expr (parse_module_decl t ~annot ~visibility)
    | Token.External ->
        Parsetree_helper.Str.extern (parse_extern t ~annot ~visibility)
    | Token.Type -> Parsetree_helper.Str.type_ (parse_type_decl t ~annot)
    | Token.Macro ->
        next t;
        Parsetree_helper.Str.macro (parse_fun_decl t ~annot ~visibility)
    | Token.Fn ->
        next t;
        Parsetree_helper.Str.fun_ (parse_fun_decl t ~annot ~visibility)
    | _ -> Error.unexpected_token t.curr_span
  in
  node

and parse_module_decl t ~annot ~visibility =
  expect Token.Module t;
  let name =
    match parse_name t with
    | Some name -> name
    | None -> Error.expected_name t.curr_span
  in
  expect Token.Brace_left t;
  let items = many parse_structure_item t in
  expect Token.Brace_right t;
  Parsetree_helper.Mod.decl ~name ~items ~annot ~visibility

and parse_module_open t =
  expect Token.Open t;
  let mod_name =
    match parse_name t with
    | Some name -> name
    | None ->
        Error.expected_symbol ~sym:(`Exact (Token.Id "Module_name"))
          ~found:t.curr_span
  in
  Parsetree_helper.Mod.open_ ~mod_name

let parse t =
  let rec parse_all acc =
    match parse_structure_item t with
    | (exception
        Error.Parse_error
          (Expected_symbol { found = { token = Token.EOF; _ }; _ }))
    | (exception Error.Parse_error End_of_file) ->
        List.rev acc
    | item -> parse_all (item :: acc)
  in
  parse_all []

(*** API ***********************************************************************)

let parse t =
  match parse t with
  | exception Lexer.Lexer_error err -> Error (`Lexer_error err)
  | exception Error.Parse_error err -> Error (`Parse_error err)
  | res -> Ok res

let make ~token_provider =
  let ( let* ) = Result.bind in
  let* last_span = Token_provider.next token_provider in
  Ok { token_provider; last_span; curr_span = last_span }
