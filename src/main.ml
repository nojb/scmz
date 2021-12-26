module L = Lambda_helper

let drawlambda = ref false
let dlambda = ref false
let compile_only = ref false
let output_name = ref ""
let stdlib_ident = Ident.create_persistent "Oont"

module Helpers = struct
  let falsev = L.int 0b01
  let truev = L.int 0b11
  let intv n = L.int (n lsl 1)
  let unsafe_toint n = L.lsrint n (L.int 1)
  let unsafe_ofint n = L.lslint n (L.int 1)
  let stringv ~loc s = L.string ~loc s
  let emptylist = L.int 0b111
  let undefined = L.int 0b1111
  let prim name = L.value "Oont" name
  let boolv b = if b then truev else falsev
  let error_exn = lazy (L.extension_constructor "Oont" "Error")
  let cons car cdr = L.makemutable 0 [ car; cdr ]

  let listv xs =
    List.fold_left (fun cdr x -> cons x cdr) emptylist (List.rev xs)

  let errorv ~loc s objs = L.makeblock 4 [ stringv ~loc s; listv objs ]
  let if_ x1 x2 x3 = L.ifthenelse (L.eq x1 falsev) x2 x3

  let type_error obj =
    L.raise
      (L.makeblock 0
         [
           Lazy.force error_exn; errorv ~loc:Location.none "Type error" [ obj ];
         ])

  let toint lam =
    Lambda.name_lambda Strict lam (fun id ->
        L.ifthenelse
          (L.isint (L.var id))
          (L.ifthenelse
             (L.andint (L.var id) (L.int 1))
             (type_error (L.var id))
             (unsafe_toint (L.var id)))
          (type_error (L.var id)))

  let apply _ _ = assert false
end

module Env : sig
  type data =
    | Psyntax of (loc:Location.t -> t -> Parser.sexp list -> Lambda.lambda)
    | Pvar of Ident.t
    | Pprim of (loc:Location.t -> Lambda.lambda list -> Lambda.lambda)

  and t

  val empty : t
  val find : string -> t -> data option

  val add_syntax :
    string ->
    (loc:Location.t -> t -> Parser.sexp list -> Lambda.lambda) ->
    t ->
    t

  val add_prim :
    string -> (loc:Location.t -> Lambda.lambda list -> Lambda.lambda) -> t -> t
end = struct
  module Map = Map.Make (String)

  type data =
    | Psyntax of (loc:Location.t -> t -> Parser.sexp list -> Lambda.lambda)
    | Pvar of Ident.t
    | Pprim of (loc:Location.t -> Lambda.lambda list -> Lambda.lambda)

  and t = { env : data Map.t }

  let empty = { env = Map.empty }
  let find s t = Map.find_opt s t.env
  let add_syntax s f t = { env = Map.add s (Psyntax f) t.env }
  let add_prim s f t = { env = Map.add s (Pprim f) t.env }
end

let get_sym s = L.apply (Helpers.prim "sym") [ L.string s ]
let num_errors = ref 0

let prerr_errorf ?loc fmt =
  incr num_errors;
  Printf.ksprintf
    (fun s ->
      Location.print_report Format.err_formatter (Location.error ?loc s);
      L.int 0)
    fmt

let rec comp_sexp env { Parser.desc; loc } =
  match desc with
  | List ({ desc = Symbol s; loc } :: args) -> (
      match Env.find s env with
      | Some (Psyntax f) -> f ~loc env args
      | Some (Pvar id) ->
          Helpers.apply (L.var id) (List.map (comp_sexp env) args)
      | Some (Pprim f) -> f ~loc (List.map (comp_sexp env) args)
      | None -> prerr_errorf ~loc "%s: not found" s)
  | Int n -> Helpers.intv n
  | List (f :: args) ->
      Helpers.apply (comp_sexp env f) (List.map (comp_sexp env) args)
  | List [] -> prerr_errorf ~loc "missing procedure"
  | Symbol s -> (
      match Env.find s env with
      | Some (Psyntax _) -> prerr_errorf ~loc "%s: bad syntax" s
      | Some (Pvar id) -> Lvar id
      | Some (Pprim _) -> assert false (* eta-expand *)
      | None -> prerr_errorf ~loc "%s: not found" s)
  | Bool b -> Helpers.boolv b

let rec comp_sexp_list env = function
  | [] -> Helpers.undefined
  | [ sexp ] -> comp_sexp env sexp
  | sexp :: sexps -> L.seq (comp_sexp env sexp) (comp_sexp_list env sexps)

let add_prim ~loc:_ = function
  | [] -> Helpers.intv 0
  | x :: xs ->
      Helpers.unsafe_ofint
        (List.fold_left
           (fun accu x ->
             let n = Helpers.toint x in
             L.addint accu n)
           (Helpers.toint x) xs)

let quote_syntax ~loc _ = function
  | [ x ] ->
      let rec quote { Parser.desc; loc = _ } =
        match desc with
        | List xs -> Helpers.listv (List.map quote xs)
        | Int n -> Helpers.intv n
        | Symbol s -> get_sym s
        | Bool b -> Helpers.boolv b
      in
      quote x
  | [] -> prerr_errorf ~loc "quote: not enough arguments"
  | _ :: _ :: _ -> prerr_errorf ~loc "quote: too many arguments"

let if_syntax ~loc env = function
  | [ x1; x2 ] ->
      Helpers.if_ (comp_sexp env x1) (comp_sexp env x2) Helpers.undefined
  | [ x1; x2; x3 ] ->
      Helpers.if_ (comp_sexp env x1) (comp_sexp env x2) (comp_sexp env x3)
  | _ -> prerr_errorf ~loc "if: bad number of arguments"

let initial_env =
  Env.add_syntax "if" if_syntax
    (Env.add_syntax "quote" quote_syntax (Env.add_prim "+" add_prim Env.empty))

let to_bytecode ~required_globals fname lam =
  let bname = Filename.remove_extension (Filename.basename fname) in
  let modname = String.capitalize_ascii bname in
  let cmofile = Filename.remove_extension fname ^ ".cmo" in
  let code = Bytegen.compile_implementation modname lam in
  let oc = open_out_bin cmofile in
  Fun.protect
    ~finally:(fun () -> close_out_noerr oc)
    (fun () -> Emitcode.to_file oc modname cmofile ~required_globals code);
  cmofile

let parse_file fname =
  let ic = open_in_bin fname in
  Fun.protect
    ~finally:(fun () -> close_in_noerr ic)
    (fun () ->
      let lexbuf = Lexing.from_channel ic in
      Location.input_name := fname;
      Location.init lexbuf fname;
      Location.input_lexbuf := Some lexbuf;
      Parser.parse_sexp_list lexbuf)

let process_file fname =
  let sexps = parse_file fname in
  let lam = comp_sexp_list initial_env sexps in
  let lam = L.apply (Helpers.prim "print") [ lam ] in
  if !drawlambda then Format.eprintf "@[%a@]@." Printlambda.lambda lam;
  if !num_errors = 0 then (
    let lam = Simplif.simplify_lambda lam in
    if !dlambda then Format.eprintf "@[%a@]@." Printlambda.lambda lam;
    let required_globals = Ident.Set.singleton stdlib_ident in
    Some (to_bytecode ~required_globals fname lam))
  else None

let spec =
  [
    ("-drawlambda", Arg.Set dlambda, " Dump IR (before simplif)");
    ("-dlambda", Arg.Set dlambda, " Dump IR (after simplif)");
    ("-c", Arg.Set compile_only, " Only compile, do not link");
    ("-o", Arg.Set_string output_name, " Set output name");
  ]

let fnames = ref []

let main () =
  Arg.parse (Arg.align spec) (fun fn -> fnames := fn :: !fnames) "";
  let libdir =
    Filename.concat
      (Filename.concat
         (Filename.dirname (Filename.dirname Sys.executable_name))
         "lib")
      "oont"
  in
  Clflags.include_dirs := libdir :: !Clflags.include_dirs;
  Clflags.debug := true;
  Compmisc.init_path ();
  let fnames = List.rev !fnames in
  let obj_names = List.filter_map process_file fnames in
  if !num_errors = 0 && not !compile_only then (
    let output_name =
      match (!output_name, fnames) with
      | "", [ fn ] -> Filename.remove_extension fn ^ ".exe"
      | "", _ :: _ :: _ -> failwith "Must specify -o"
      | s, _ -> s
    in
    Compmisc.init_path ();
    Bytelink.link ("oont.cma" :: obj_names) output_name)

let () =
  try main () with exn -> Location.report_exception Format.err_formatter exn
