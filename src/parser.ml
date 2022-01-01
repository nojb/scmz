type desc =
  | List of sexp list
  | Atom of string
  | Int of int
  | Bool of bool
  | Vector of sexp list

and sexp = { desc : desc; loc : Location.t }

let merge_loc { Location.loc_start; _ } { Location.loc_end; _ } =
  { Location.loc_start; loc_end; loc_ghost = false }

let rec print_sexp ppf x =
  match x.desc with
  | List sexpl ->
      Format.fprintf ppf "@[<1>(%a)@]"
        (Format.pp_print_list ~pp_sep:Format.pp_print_space print_sexp)
        sexpl
  | Atom s -> Format.pp_print_string ppf s
  | Int n -> Format.pp_print_int ppf n
  | Bool true -> Format.pp_print_string ppf "#t"
  | Bool false -> Format.pp_print_string ppf "#f"
  | Vector sexpl ->
      Format.fprintf ppf "@[<2>#(%a)@]"
        (Format.pp_print_list ~pp_sep:Format.pp_print_space print_sexp)
        sexpl

let rec parse_sexp toks =
  match toks with
  | { Lexer.desc = Lparen; loc = loc1 } :: toks ->
      let rec loop accu toks =
        match toks with
        | { Lexer.desc = Rparen; loc = loc2 } :: toks ->
            ({ desc = List (List.rev accu); loc = merge_loc loc1 loc2 }, toks)
        | _ ->
            let x, toks = parse_sexp toks in
            loop (x :: accu) toks
      in
      loop [] toks
  | { desc = HASHLPAREN; loc = loc1 } :: toks ->
      let rec loop accu toks =
        match toks with
        | { Lexer.desc = Rparen; loc = loc2 } :: toks ->
            ({ desc = Vector (List.rev accu); loc = merge_loc loc1 loc2 }, toks)
        | _ ->
            let x, toks = parse_sexp toks in
            loop (x :: accu) toks
      in
      loop [] toks
  | { desc = Quote; loc } :: toks ->
      let x, toks = parse_sexp toks in
      ( {
          desc = List [ { desc = Atom "quote"; loc }; x ];
          loc = merge_loc loc x.loc;
        },
        toks )
  | { desc = Quasiquote; loc } :: toks ->
      let x, toks = parse_sexp toks in
      ( {
          desc = List [ { desc = Atom "quasiquote"; loc }; x ];
          loc = merge_loc loc x.loc;
        },
        toks )
  | { desc = Unquote; loc } :: toks ->
      let x, toks = parse_sexp toks in
      ( {
          desc = List [ { desc = Atom "unquote"; loc }; x ];
          loc = merge_loc loc x.loc;
        },
        toks )
  | { desc = Unquote_splicing; loc } :: toks ->
      let x, toks = parse_sexp toks in
      ( {
          desc = List [ { desc = Atom "unquote-splicing"; loc }; x ];
          loc = merge_loc loc x.loc;
        },
        toks )
  | { desc = Int s; loc } :: toks ->
      ({ desc = Int (int_of_string s); loc }, toks)
  | { desc = Atom s; loc } :: toks -> ({ desc = Atom s; loc }, toks)
  | { desc = False; loc } :: toks -> ({ desc = Bool false; loc }, toks)
  | { desc = True; loc } :: toks -> ({ desc = Bool true; loc }, toks)
  | _ -> failwith "syntax error"

let parse_sexp_list lexbuf =
  let rec loop toks =
    match Lexer.token lexbuf with
    | None -> List.rev toks
    | Some tok -> loop (tok :: toks)
  in
  let toks = loop [] in
  let rec loop sexps = function
    | [] -> List.rev sexps
    | toks ->
        let x, toks = parse_sexp toks in
        loop (x :: sexps) toks
  in
  loop [] toks
