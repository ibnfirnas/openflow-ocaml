module M = Mpl_stdlib
open Openflow_packet

let path_of_switch name = Printf.sprintf "/var/run/openvswitch/%s.mgmt" name

let with_socket name f =
    let fd = Unix.socket Unix.PF_UNIX Unix.SOCK_STREAM 0 in
    Pervasiveext.finally 
	(fun () ->
	     let sa = Unix.ADDR_UNIX (path_of_switch "xenbr0") in
	     Unix.connect fd sa;
	     f fd
	)
    	(fun () -> Unix.close fd)

(** No switch port *)
let no_port = Openflow_port.t ~port:`NONE

(** A flow match which matches all traffic *)
let match_anything =
	let no_port = Openflow_port.t ~port:`NONE in 
	let wildcards = Openflow_flow_wildcards.t ~nw_tos:1 ~dl_vlan_pcp:1
		~nw_dst:0b111111 ~nw_src:0b111111 ~tp_dst:1 ~tp_src:1 ~nw_proto:1
		~dl_type:1 ~dl_dst:1 ~dl_src:1 ~dl_vlan:1 ~in_port:1 in
	let eth = `Str(String.make 6 '\000') in
	Openflow_match.t ~wildcards ~in_port:no_port
		~dl_src:eth ~dl_dst:eth ~dl_vlan:0 ~dl_vlan_pcp:0 ~dl_type:0 
		~nw_tos:0 ~nw_proto:0 ~nw_src:0l ~nw_dst:0l ~tp_src:0 ~tp_dst:0

let hello = HELLO.t ~data:(`Str "")

let with_connection name f = 
	with_socket name
	(fun fd ->
		let env = M.new_env (String.make 16384 '\000') in
		let senv = M.new_env (String.make 1000 '\000') in
		let id = ref 0l in
		let next_id () = id := Int32.add !id 1l; !id in
		let send f = 
			M.reset senv;     
			f ~version:1 ~xid:(next_id ()) senv;
			M.flush senv fd in
		let recv handler = 
			M.reset env;
			M.fill env fd;
			let o = Openflow_packet.unmarshal env in
			handler o in
		(* Exchange version numbers *)
		send hello;
		recv (fun x -> match x with 
			| `HELLO o ->
				(* NB this is a simultaneous message *)
				if o#version <> 1
				then failwith (Printf.sprintf "Unexpected version: got %d wanted %d" o#version 1);
				()
			| _ ->
				failwith "Expected HELLO"
		);
		f send recv		
	)

 
let vendor ~version ~xid env = 
 	let xensource_oui = 0x163el in (* an example *)
	let (_: VENDOR.o) = VENDOR.t ~version ~xid ~vendor:xensource_oui ~data:(`Str "") env in
	()
 
let features_request ~version ~xid env = 
	let (_: FEATURES_REQUEST.o) = FEATURES_REQUEST.t ~version ~xid ~data:(`Str "") env in
	()
 
let get_config_request ~version ~xid env = 
	let (_: GET_CONFIG_REQUEST.o) = GET_CONFIG_REQUEST.t ~version ~xid env in 
	()
 
let set_config ~version ~xid env = 
	let (_: SET_CONFIG.o) = SET_CONFIG.t ~version ~xid ~reasm:0 ~drop:0 ~miss_send_len:0 env in 
	()
 
let descr_stats_request ~version ~xid env = 
	let (_: STATS_REQUEST.DESCR.o) = STATS_REQUEST.DESCR.t ~version ~xid env in 
	()
 
let flow_stats_request ~version ~xid env =
	let (_: STATS_REQUEST.FLOW.o) = STATS_REQUEST.FLOW.t ~version ~xid ~ofp_match:match_anything ~table_id:`ALL ~out_port:no_port env in 
	()
 
 

let features_reply x = match x with 
|`FEATURES_REPLY o ->
	FEATURES_REPLY.prettyprint o;
	M.fold_env o#data_env
		(fun env () ->
			let o = Openflow_phy_port.unmarshal env in
			Openflow_phy_port.prettyprint o;
		) ()

| _ -> failwith "Not a FEATURES_REPLY"

let stats_reply x = match x with 
|`STATS_REPLY o -> STATS_REPLY.prettyprint o;
| _ -> failwith "Not a STATS_REPLY"

let _ =
	Printf.printf "About to connect\n"; flush stdout;
	with_connection "xenbr0"
	(fun send recv ->
		Printf.printf "VENDOR\n"; flush stdout;
		send vendor;
		recv prettyprint;
		Printf.printf "FEATURES_REQUEST\n"; flush stdout;
		send features_request;
		recv features_reply;
		Printf.printf "GET_CONFIG_REQUEST\n"; flush stdout;
		send get_config_request;
		recv prettyprint;
		Printf.printf "STATS_REQUEST(DESCR)\n"; flush stdout;
		send descr_stats_request;
		recv stats_reply;
		Printf.printf "STATS_REQUEST(FLOW)\n"; flush stdout;
		send flow_stats_request;
		recv stats_reply;
		Printf.printf "SET_CONFIG\n"; flush stdout;
		send set_config;
		(* SET_CONFIG has no response. We make sure the connection hasn't lost
		   sync by sending any message which elicits a response. *)
		send descr_stats_request;
		recv stats_reply;
		Printf.printf "Done\n";
	)
