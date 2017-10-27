(* generate ocaml docker containers *)
module L = Dockerfile_linux
module D = Dockerfile_distro
module C = Dockerfile_cmd
module CU = Dockerfile_cmd.Utils
module G = Dockerfile_gen

module Gen = struct
  open Dockerfile
  open Dockerfile_opam
  (* Build the OPAM distributions from the OCaml base *)
  let add_comment ?compiler_version tag =
    comment "OPAM for %s with %s" tag
      (match compiler_version with
       | None -> "system OCaml compiler"
       | Some v -> "local switch of OCaml " ^ v)

  (* Apk based Dockerfile *)
  let apk_opam2 ?(labels=[]) ~distro ~tag () =
    header distro tag @@
    label (("distro_style", "apk")::labels) @@
    L.Apk.install "build-base bzip2 git tar curl ca-certificates" @@
    install_opam_from_source ~install_wrappers:true ~branch:"master" () @@
    run "strip /usr/local/bin/opam*" @@
    from ~tag distro @@
    copy ~from:"0" ~src:["/usr/local/bin/opam"] ~dst:"/usr/bin/opam" () @@
    copy ~from:"0" ~src:["/usr/local/bin/opam-installer"] ~dst:"/usr/bin/opam-installer" () @@
    L.Apk.install "build-base tar ca-certificates git rsync curl sudo" @@ 
    L.Apk.add_user ~sudo:true "opam" @@
    L.Git.init ()

  (* Debian based Dockerfile *)
  let apt_opam2 ?(labels=[]) ~distro ~tag () =
    header distro tag @@
    label (("distro_style", "apt")::labels) @@
    L.Apt.install "build-essential curl git" @@
    install_opam_from_source ~install_wrappers:true ~branch:"master" () @@
    run "strip /usr/local/bin/opam*" @@
    from ~tag distro @@
    copy ~from:"0" ~src:["/usr/local/bin/opam"] ~dst:"/usr/bin/opam" () @@
    copy ~from:"0" ~src:["/usr/local/bin/opam-installer"] ~dst:"/usr/bin/opam-installer" () @@
    L.Apt.install "build-essential curl git rsync sudo unzip" @@
    L.Git.init ()

  (* Generate archive mirror *)
  let opam2_mirror (hub_id:string) =
    header hub_id "alpine-3.6" @@
    run "sudo apk add --update bash m4" @@
    run "git clone git://github.com/ocaml/opam-repository /home/opam/opam-repository --depth 1" @@
    workdir "/home/opam/opam-repository" @@
    run "opam admin upgrade" @@
    run "opam admin cache" @@
    run "opam init -a /home/opam/opam-repository" @@
    run "opam install -yj4 cohttp-lwt-unix"

  let ocaml_compilers hub_id arch distro =
    let distro = D.tag_of_distro distro in
    let compilers = D.stable_ocaml_versions |> List.filter (D.ocaml_supported_on arch) |> List.map (run "opam switch create %s") |> (@@@) empty in
    let d = 
      header hub_id distro @@
      run "git clone git://github.com/ocaml/opam-repository /home/opam/opam-repository --depth 1" @@
      run "opam init -a /home/opam/opam-repository" @@
      compilers @@
      run "opam switch default" in
    distro, d

  let gen_opam_for_distro ?labels d =
    match D.resolve_alias d with
    | `Alpine v ->
      let tag = match v with
        | `V3_3 -> "3.3" | `V3_4 -> "3.4"
        | `V3_5 -> "3.5" | `V3_6 -> "3.6"
        | `Latest -> assert false in
      Some (D.tag_of_distro d, (apk_opam2 ?labels ~distro:"alpine" ~tag ()))
    | `Debian v ->
      let tag = match v with
        | `V7 -> "7"
        | `V8 -> "8"
        | `V9 -> "9"
        | `Testing -> "testing"
        | `Unstable -> "unstable"
        | `Stable -> assert false in
      Some (D.tag_of_distro d, (apt_opam2 ?labels ~distro:"debian" ~tag ()))
    | `Ubuntu v ->
      let tag = match v with
        | `V12_04 -> "precise"
        | `V14_04 -> "trusty"
        | `V16_04 -> "xenial"
        | `V16_10 -> "yakkety"
        | `V17_04 -> "zesty"
        | `V17_10 -> "artful"
        | _ -> assert false in
      Some (D.tag_of_distro d, (apt_opam2 ?labels ~distro:"ubuntu" ~tag ()))
    | _ -> None
end

module Phases = struct

  open Rresult
  open R.Infix

  let arch_to_docker =
    function
    | `X86_64 -> "amd64"
    | `Aarch64 -> "arm64"

  let with_log_dirs build_dir logs_dir fn =
    let build_dir = Fpath.v build_dir in
    let logs_dir = Fpath.v logs_dir in
    Bos.OS.Dir.create ~path:true build_dir >>= fun _ ->
    Bos.OS.Dir.create ~path:true logs_dir >>= fun _ ->
    fn build_dir logs_dir

  let phase1 arch hub_id build_dir logs_dir () =
    with_log_dirs build_dir logs_dir (fun build_dir logs_dir ->
    let d =
      List.filter (D.distro_supported_on arch) D.active_distros |>
      List.map Gen.gen_opam_for_distro |>
      List.fold_left (fun a -> function Some x -> x::a | None -> a) [] in
    G.generate_dockerfiles ~crunch:false build_dir d >>= fun () ->
    let dockerfile = Fpath.(build_dir / "Dockerfile.{}") in
    let arch_s = arch_to_docker arch in
    let gen_tag d = Fmt.strf "%s:linux-%s-opam-%s" hub_id arch_s d in
    let tag = gen_tag "{}" in
    let cmd = C.Docker.build_cmd ~cache:false ~dockerfile ~tag (Fpath.v ".") in
    let args = List.map fst d in
    C.Parallel.run ~retries:1 ~results:logs_dir cmd args >>= fun jobs ->
    Logs.debug (fun l -> l "joblog: %s" (Sexplib.Sexp.to_string_hum (C.Parallel.sexp_of_t jobs)));
    CU.iter (fun job ->
      gen_tag job.C.Parallel.Joblog.arg |>
      C.Docker.push_cmd |>
      CU.run_out >>= fun _ -> Ok ()
    ) jobs
    )

  let phase2 hub_id () =
    List.iter (fun distro ->
        let arches = D.distro_arches distro in
        let platforms = List.map (fun a -> Fmt.strf "linux/%s" (arch_to_docker a)) arches in
        let template = Fmt.strf "%s:OS-ARCH-opam-%s" hub_id (D.tag_of_distro distro) in
        let target = Fmt.strf "%s:%s" hub_id (D.tag_of_distro distro) in
        C.Docker.manifest_push ~platforms ~template ~target |>
        CU.run_out |> R.is_ok |> fun _ -> () (* TODO *)
      ) D.active_distros;
    R.ok ()

  let phase3_archive hub_id build_dir logs_dir () =
    let d = Gen.opam2_mirror hub_id in 
    let build_dir = Fpath.(v build_dir / "archive") in
    let _logs_dir = Fpath.v logs_dir in
    Bos.OS.Dir.create ~path:true build_dir >>= fun _ ->
    G.generate_dockerfile ~crunch:true build_dir d >>= fun () ->
    Bos.OS.Dir.set_current build_dir >>= fun () -> 
    (C.Docker.build_cmd ~cache:false ~tag:"opam2-archive" (Fpath.v ".") |> CU.run_out) >>= fun _ ->
    R.ok ()

  let phase3_megaocaml arch hub_id build_dir logs_dir () =
    with_log_dirs build_dir logs_dir (fun build_dir logs_dir ->
    let d =
      List.filter (D.distro_supported_on arch) D.active_distros |>
      List.map (Gen.ocaml_compilers hub_id arch) in
    G.generate_dockerfiles ~crunch:true build_dir d >>= fun () ->
    let dockerfile = Fpath.(build_dir / "Dockerfile.{}") in
    let arch_s = arch_to_docker arch in
    let gen_tag d = Fmt.strf "%s:linux-%s-ocaml-all-%s" hub_id arch_s d in
    let tag = gen_tag "{}" in
    let cmd = C.Docker.build_cmd ~cache:false ~dockerfile ~tag (Fpath.v ".") in
    let args = List.map fst d in
    C.Parallel.run ~retries:1 ~results:logs_dir cmd args >>= fun _ -> Ok ()
    )

  let phase3_ocaml arch hub_id build_dir logs_dir () =
    with_log_dirs build_dir logs_dir (fun build_dir logs_dir ->
    let d =
      List.filter (D.distro_supported_on arch) D.active_distros |>
      List.map (Gen.ocaml_compilers hub_id arch) in
    G.generate_dockerfiles ~crunch:true build_dir d >>= fun () ->
    let dockerfile = Fpath.(build_dir / "Dockerfile.{}") in
    let arch_s = arch_to_docker arch in
    let gen_tag d = Fmt.strf "%s:linux-%s-ocaml-all-%s" hub_id arch_s d in
    let tag = gen_tag "{}" in
    let cmd = C.Docker.build_cmd ~cache:false ~dockerfile ~tag (Fpath.v ".") in
    let args = List.map fst d in
    C.Parallel.run ~retries:1 ~results:logs_dir cmd args >>= fun _ -> Ok ()
    )


end

open Cmdliner
let setup_logs = C.setup_logs ()

let hub_id =
  let doc = "Docker Hub user/repo to push to" in
  Arg.(value & opt string "ocaml/opam2-staging" & info ["hub-id"] ~docv:"HUB_ID" ~doc)

let build_dir = 
  let doc = "Directory in which to store build artefacts" in
  Arg.(value & opt file "_build" & info ["b";"build-dir"] ~docv:"BUILD_DIR" ~doc)

let logs_dir =
  let doc = "Directory in which to store logs" in
  Arg.(value & opt file "_logs" & info ["l";"logs-dir"] ~docv:"LOG_DIR" ~doc)

let arch =
  let doc = "CPU architecture to perform build on" in
  let term = Arg.enum ["x86_64",`X86_64; "aarch64",`Aarch64] in
  Arg.(value & opt term `X86_64 & info ["arch"] ~docv:"ARCH" ~doc)

let phase1_cmd =
  let doc = "generate, build and push base opam container images" in
  let exits = Term.default_exits in
  let man = [
    `S Manpage.s_description;
    `P "Generate and build base $(b,opam) container images." ]
  in
  Term.(term_result (const Phases.phase1 $ arch $ hub_id $ build_dir $ logs_dir $ setup_logs)),
  Term.info "phase1" ~doc ~sdocs:Manpage.s_common_options ~exits ~man

let phase2_cmd =
  let doc = "combine opam container images into multiarch versions" in
  let exits = Term.default_exits in
  Term.(term_result (const Phases.phase2 $ hub_id $ setup_logs)),
  Term.info "phase2" ~doc ~exits

let phase3_archive_cmd =
  let doc = "generate a distribution archive mirror" in
  let exits = Term.default_exits in
  Term.(term_result (const Phases.phase3_archive $ hub_id $ build_dir $ logs_dir $ setup_logs)),
  Term.info "phase3-cache" ~doc ~exits

let phase3_megaocaml_cmd =
  let doc = "generate a ocaml compiler container with all the things" in
  let exits = Term.default_exits in
  Term.(term_result (const Phases.phase3_megaocaml $ arch $ hub_id $ build_dir $ logs_dir $ setup_logs)),
  Term.info "phase3-ocaml" ~doc ~exits

let phase3_ocaml_cmd =
  let doc = "generate a matrix of ocaml compilers" in
  let exits = Term.default_exits in
  Term.(term_result (const Phases.phase3_ocaml $ arch $ hub_id $ build_dir $ logs_dir $ setup_logs)),
  Term.info "phase3-ocaml" ~doc ~exits


let default_cmd =
  let doc = "build and push opam and OCaml multiarch container images" in
  let sdocs = Manpage.s_common_options in
  Term.(ret (const (fun _ -> `Help (`Pager, None)) $ pure ())),
  Term.info "obi-docker" ~version:"v1.0.0" ~doc ~sdocs

let cmds = [phase1_cmd; phase2_cmd; phase3_archive_cmd; phase3_megaocaml_cmd; phase3_ocaml_cmd]
let () = Term.(exit @@ eval_choice default_cmd cmds)
