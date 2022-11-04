module Types = Db.Types
open Odoc_model
module ModuleName = Odoc_model.Names.ModuleName

let copy str = String.init (String.length str) (String.get str)

let deep_copy (type t) (x : t) : t =
  let buf = Marshal.(to_bytes x [ No_sharing; Closures ]) in
  Marshal.from_bytes buf 0

module Cache_doc = Cache.Make (struct
  type t = Html_types.li_content_fun Tyxml.Html.elt

  let copy x = deep_copy x
end)

module Cache_name = Cache.Make (struct
  type t = string

  let copy = copy
end)

module Cache = Cache.Make (struct
  type t = string

  let copy = copy
end)

let clear () =
  Cache.clear () ;
  Cache_name.clear () ;
  Cache_doc.clear ()

let rec type_size = function
  | Odoc_model.Lang.TypeExpr.Var _ -> 1
  | Any -> 1
  | Arrow (lbl, a, b) ->
      (match lbl with
      | None -> 0
      | Some _ -> 1)
      + type_size a + type_size b
  | Constr (_, args) -> List.fold_left (fun acc t -> acc + type_size t) 1 args
  | Tuple args -> List.fold_left (fun acc t -> acc + type_size t) 1 args
  | _ -> 100

let rev_concat lst =
  List.fold_left (fun acc xs -> List.rev_append xs acc) [] lst

let rec tails = function
  | [] -> []
  | _ :: xs as lst -> lst :: tails xs

let fullname t =
  Pretty.fmt_to_string (fun h -> Pretty.show_type_name_verbose h t)

let all_type_names t =
  let fullname = fullname t in
  tails (String.split_on_char '.' fullname)

let rec paths ~prefix ~sgn = function
  | Odoc_model.Lang.TypeExpr.Var _ ->
      let poly = Cache_name.memo "POLY" in
      [ poly :: Cache_name.memo (Types.string_of_sgn sgn) :: prefix ]
  | Any ->
      let poly = Cache_name.memo "POLY" in
      [ poly :: Cache_name.memo (Types.string_of_sgn sgn) :: prefix ]
  | Arrow (_, a, b) ->
      let prefix_left = Cache_name.memo "->0" :: prefix in
      let prefix_right = Cache_name.memo "->1" :: prefix in
      List.rev_append
        (paths ~prefix:prefix_left ~sgn:(Types.sgn_not sgn) a)
        (paths ~prefix:prefix_right ~sgn b)
  | Constr (name, args) ->
      let name = fullname name in
      let prefix =
        Cache_name.memo name
        :: Cache_name.memo (Types.string_of_sgn sgn)
        :: prefix
      in
      begin
        match args with
        | [] -> [ prefix ]
        | _ ->
            rev_concat
            @@ ExtLib.List.mapi
                 (fun i arg ->
                   let prefix = Cache_name.memo (string_of_int i) :: prefix in
                   paths ~prefix ~sgn arg)
                 args
      end
  | Tuple args ->
      rev_concat
      @@ ExtLib.List.mapi (fun i arg ->
             let prefix = Cache_name.memo (string_of_int i ^ "*") :: prefix in
             paths ~prefix ~sgn arg)
      @@ args
  | _ -> []

let rec type_paths ~prefix ~sgn = function
  | Odoc_model.Lang.TypeExpr.Var _ ->
      [ "POLY" :: Types.string_of_sgn sgn :: prefix ]
  | Any -> [ "POLY" :: Types.string_of_sgn sgn :: prefix ]
  | Arrow (_lbl, a, b) ->
      List.rev_append
        (type_paths ~prefix ~sgn:(Types.sgn_not sgn) a)
        (type_paths ~prefix ~sgn b)
  | Constr (name, args) ->
      rev_concat
      @@ ExtLib.List.map (fun name ->
             let name = String.concat "." name in
             let prefix = name :: Types.string_of_sgn sgn :: prefix in
             begin
               match args with
               | [] -> [ prefix ]
               | _ ->
                   rev_concat
                   @@ ExtLib.List.mapi
                        (fun i arg ->
                          let prefix = string_of_int i :: prefix in
                          type_paths ~prefix ~sgn arg)
                        args
             end)
      @@ all_type_names name
  | Tuple args -> rev_concat @@ ExtLib.List.map (type_paths ~prefix ~sgn) @@ args
  | _ -> []

let save_item ~pkg ~path_list ~path name type_ doc =
  let b = Buffer.create 16 in
  let to_b = Format.formatter_of_buffer b in
  Format.fprintf to_b "%a%!"
    (Pretty.show_type
       ~path:(Pretty.fmt_to_string (fun h -> Pretty.pp_path h path))
       ~parens:false)
    type_ ;
  let str_type = Buffer.contents b in
  Buffer.reset b ;
  Format.fprintf to_b "%a%s%!" Pretty.pp_path path
    (Odoc_model.Names.ValueName.to_string name) ;
  let full_name = Buffer.contents b in
  let doc = Option.map Cache_doc.memo (Pretty.string_of_docs doc) in
  let cost =
    String.length full_name + String.length str_type
    + (5 * List.length path)
    + type_size type_
    + (match doc with
      | None -> 1000
      | _ -> 0)
    + if String.starts_with ~prefix:"Stdlib." full_name then -100 else 0
  in
  let paths = paths ~prefix:[] ~sgn:Pos type_ in
  let str_type =
    { Db.Elt.name = full_name
    ; cost
    ; type_paths = paths
    ; str_type = Cache.memo str_type
    ; doc
    ; pkg
    }
  in
  let my_full_name =
    List.rev_append
      (Db.list_of_string (Odoc_model.Names.ValueName.to_string name))
      ('.' :: path_list)
  in
  let my_full_name = ExtLib.List.map Char.lowercase_ascii my_full_name in
  Db.store_name my_full_name str_type ;
  let type_paths = type_paths ~prefix:[] ~sgn:Pos type_ in
  Db.store_all str_type (ExtLib.List.map (ExtLib.List.map Cache_name.memo) type_paths)

let rec item ~pkg ~path_list ~path =
  let open Odoc_model.Lang in
  function
  | Signature.Value { id = `Value (_, name); _ }
    when Odoc_model.Names.ValueName.is_internal name ->
      ()
  | Signature.Value { id = `Value (_, name); type_; doc; _ } ->
      save_item ~pkg ~path_list ~path name type_ doc
  | Module (_, mdl) ->
      let name = Paths.Identifier.name mdl.id in
      if name = "Stdlib" then () else module_items ~pkg ~path_list ~path mdl
  | Type (_, _) -> ()
  | Include icl -> items ~pkg ~path_list ~path icl.expansion.content.items
  | TypeSubstitution _ -> () (* type t = Foo.t = actual_definition *)
  | TypExt _ -> () (* type t = .. *)
  | Exception _ -> ()
  | Class _ -> ()
  | ClassType _ -> ()
  | Comment _ -> ()
  | Open _ -> ()
  | ModuleType _ -> ()
  | ModuleSubstitution _ -> ()
  | ModuleTypeSubstitution _ -> ()

and items ~pkg ~path_list ~path item_list =
  List.iter (item ~pkg ~path_list ~path) item_list

and module_items ~pkg ~path_list ~path mdl =
  let open Odoc_model.Lang.Module in
  let name = Paths.Identifier.name mdl.id in
  let path = name :: path in
  let path_list = List.rev_append (Db.list_of_string name) ('.' :: path_list) in
  match mdl.type_ with
  | ModuleType e -> module_type_expr ~pkg ~path_list ~path e
  | Alias (_, Some mdl) -> module_items_ty ~pkg ~path_list ~path mdl
  | Alias (_, None) -> ()

and module_type_expr ~pkg ~path_list ~path = function
  | Signature sg -> items ~pkg ~path_list ~path sg.items
  | Functor (_, sg) -> module_type_expr ~pkg ~path_list ~path sg
  | With { w_expansion = Some sg; _ }
  | TypeOf { t_expansion = Some sg; _ }
  | Path { p_expansion = Some sg; _ } ->
      simple_expansion ~pkg ~path_list ~path sg
  | With _ -> ()
  | TypeOf _ -> ()
  | Path _ -> ()
  | _ -> .

and simple_expansion ~pkg ~path_list ~path = function
  | Signature sg -> items ~pkg ~path_list ~path sg.items
  | Functor (_, sg) -> simple_expansion ~pkg ~path_list ~path sg

and module_items_ty ~pkg ~path_list ~path = function
  | Functor (_, mdl) -> module_items_ty ~pkg ~path_list ~path mdl
  | Signature sg -> items ~pkg ~path_list ~path sg.items

module Resolver = Odoc_odoc.Resolver

let run ~odoc_directory (root_name, filename) =
  let ((package, version) as pkg) =
    match String.split_on_char '/' filename with
    | "." :: package :: version :: _ -> package, version
    | _ ->
        invalid_arg (Printf.sprintf "not a valid package/version? %S" filename)
  in
  Printf.printf "%s %s => %s\n%!" package version root_name ;
  let filename = Filename.concat odoc_directory filename in
  let fpath = Result.get_ok @@ Fpath.of_string filename in
  let t =
    match Odoc_odoc.Odoc_file.load fpath with
    | Ok { Odoc_odoc.Odoc_file.content = Unit_content t; _ } -> t
    | Ok { Odoc_odoc.Odoc_file.content = Page_content _; _ } ->
        failwith "page content"
    | Error (`Msg m) -> failwith ("ERROR:" ^ m)
  in
  let open Odoc_model.Lang.Compilation_unit in
  match t.content with
  | Pack _ -> ()
  | Module t ->
      let path = [ root_name ] in
      let path_list = List.rev (Db.list_of_string root_name) in
      items ~pkg ~path_list ~path t.Odoc_model.Lang.Signature.items
