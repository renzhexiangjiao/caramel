open Caramel_caml
open Caramel_misc
open Caramel_sugarcane
open Caramel_syntax
open Caramel_typing
open Sexplib.Std

(* TODO(@ostera): turn these back from `string` to `Fpath.t` *)
type opts = {
  sources : string list;
  stdlib : string option;
  dump_parsetree : bool;
  dump_typedtree : bool;
  dump_ir : bool;
  dump_pass : int;
  dump_erl_ast : bool;
  print_time : bool;
  new_syntax : bool;
  to_beam : bool;
}
[@@deriving sexp]

type t = { opts : opts }

let compile_one ~t ~caml:_ source =
  let ( let* ) = Stdlib.Result.bind in

  let* unit = Compilation_unit.from_source source in

  Logs.debug (fun f -> f "Compiling unit: %a\n" Compilation_unit.pp unit);

  match Compilation_unit.source_kind unit with
  | Interface ->
      let* parsetree = Syntax.parse_interface ~unit in
      if t.opts.dump_parsetree then
        Output.write ~unit ~ext:".parsetree" Syntax.pp_intf parsetree;

      let* interface = Typing.check_interface ~unit ~parsetree in
      if t.opts.dump_typedtree then
        Output.write ~unit ~ext:".typedtree" Typing.pp_intf interface;

      Logs.debug (fun f -> f "Done");

      Ok ()
  | Implementation ->
      let* parsetree =
        if t.opts.new_syntax then
          let open Caramel_newsyntax in
          Syntax.parse
            {
              source_file = unit.source_file;
              debug = false;
              dump_parsetree = false;
              dump_tokens = false;
              dump_caml = false;
              dump_macro_env = false;
              dump_expanded = false;
            }
        else Syntax.parse_implementation ~unit
      in
      if t.opts.dump_parsetree then
        Output.write ~unit ~ext:".parsetree" Syntax.pp_impl parsetree;

      let* typedunit = Typing.check_implementation ~unit ~parsetree in
      if t.opts.dump_typedtree then
        Output.write ~unit ~ext:".lambda" Typing.pp_impl typedunit;

      Logs.debug (fun f -> f "Translating to IR...");
      let tunit =
        Sugarcane.Translation_unit.make ~print_time:t.opts.print_time
          ~dump_pass:t.opts.dump_pass ~unit ~program:typedunit
      in
      let tunit = Sugarcane.translate tunit in
      if t.opts.dump_ir then
        Output.write ~unit ~ext:".ir" Sugarcane.IR.pp tunit.ir;

      Logs.debug (fun f -> f "Translating to B...");
      let b = Sugarcane.to_b_lang tunit in
      if t.opts.dump_ir then Output.write_many ~unit ~ext:".b" Sugarcane.B.pp b;

      let* core_files = Sugarcane.codegen ~tunit ~b in

      let* () = if t.opts.to_beam then Erlc.compile core_files else Ok () in

      Logs.debug (fun f -> f "Done");

      Ok ()

let compile_all ~t ~caml ~sources =
  List.fold_left
    (fun acc src ->
      match (acc, compile_one ~t ~caml src) with
      | last, Ok () -> last
      | last, Error `Early_exit -> last
      | _, Error (`Msg txt) ->
          Format.fprintf Format.err_formatter "%s" txt;
          Error ()
      | _, Error (`Lexer_error e) ->
          Caramel_newsyntax.Lexer.pp_error Format.std_formatter e;
          Error ()
      | _, Error (`Parse_error e) ->
          Caramel_newsyntax.Parser.Error.pp Format.std_formatter e;
          Error ()
      | _, Error (`Runtime_error e) ->
          Caramel_newsyntax.Macro_expander.Error.pp Format.std_formatter e;
          Error ()
      | _, Error (`Invalid_extension _ as e) ->
          Source_kind.print_error e;
          Error ()
      | _, Error (`Caml_typing_error e) ->
          Caml.print_type_error e;
          Error ()
      | _, Error (`Caml_parse_error e) ->
          Caml.print_parse_error e;
          Error ())
    (Ok ()) sources

let run ({ sources; stdlib; _ } as opts) =
  Logs.debug (fun f ->
      f "Running Sugarcane compiler on sources: \n%s\n"
        (Sexplib.Sexp.to_string_hum ~indent:2 (sexp_of_opts opts)));

  let sources = List.map Fpath.v sources in

  let caml =
    Caml.init
      {
        stdlib = Option.map Fpath.v stdlib;
        tool_name = "caramel";
        opened_modules = [];
        include_dirs = [];
      }
  in

  compile_all ~t:{ opts } ~caml ~sources
