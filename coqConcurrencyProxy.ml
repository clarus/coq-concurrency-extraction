(** Activate the trace of all the messages exchanged with the client. *)
let debug = false

module State = struct
  let clients : Lwt_unix.file_descr Heap.t ref = ref Heap.empty
end

(** Print an error message and flush the output. *)
let print_error (message : string) : unit Lwt.t =
  Lwt.bind (Lwt_io.write_line Lwt_io.stderr message) (fun _ ->
  Lwt_io.flush Lwt_io.stderr)

(** Print a message for the client on the standard output. *)
let print (message : string) : unit Lwt.t =
  Lwt.bind (
    if debug then
      print_error ("IN: " ^ message)
    else
      Lwt.return ()) (fun _ ->
  Lwt_io.printl message)

module Log = struct
  let write (id : string) (arguments : string list) : unit Lwt.t =
    match arguments with
    | [message] ->
      let message = Base64.decode message in
      Lwt.catch (fun _ ->
        Lwt.bind (Lwt_io.write_line Lwt_io.stderr message) (fun _ ->
        print ("Log " ^ id ^ " true")))
        (fun _ -> print ("Log " ^ id ^ " false"))
    | _ -> Lwt.fail (Failure "one argument was expected")
end

module File = struct
  let read (id : string) (arguments : string list) : unit Lwt.t =
    match arguments with
    | [file_name] ->
      Lwt.catch (fun _ ->
        Lwt.bind (Lwt_io.open_file Lwt_io.Input (Base64.decode file_name)) (fun file ->
        Lwt.bind (Lwt_io.read file) (fun content ->
        let content = Base64.encode content in
        print ("FileRead " ^ id ^ " " ^ content))))
        (fun _ -> print ("FileRead " ^ id ^ " "))
    | _ -> Lwt.fail (Failure "one argument was expected")
end

module ClientSocket = struct
  let rec read (id : string) (arguments : string list) : unit Lwt.t =
    match arguments with
    | [client_id] ->
      Lwt.catch (fun _ ->
        let client_id = Heap.Id.of_string client_id in
        (match Heap.find !State.clients client_id with
        | None -> Lwt.fail (Failure "Client socket not found.")
        | Some client ->
            let buffer_size = 1024 in
            let buffer = String.create buffer_size in
            Lwt.bind (Lwt_unix.recv client buffer 0 buffer_size []) (fun bytes ->
            if 0 < bytes && bytes < buffer_size then (* TODO: accept messages of empty size? *)
              let message = Base64.encode (String.sub buffer 0 bytes) in
              Lwt.bind (print ("ClientSocketRead " ^ id ^ " " ^ message)) (fun _ ->
              read id arguments)
            else
              Lwt.fail (Failure "Invalid number of bytes."))))
        (fun _ -> print ("ClientSocketRead " ^ id ^ " "))
    | _ -> Lwt.fail (Failure "one argument was expected")

  (** Repeat the send Unix command until all the message is sent. *)
  let rec send (client : Lwt_unix.file_descr) (message : string)
    (start_index : int) (length : int) : unit Lwt.t =
    Lwt.bind (Lwt_unix.send client message start_index length []) (fun n ->
    if n < 0 then
      Lwt.fail (Failure "positive number of sent bytes expected")
    else if n <> length then
      send client message (start_index + n) (length - n)
    else
      Lwt.return ())

  let write (id : string) (arguments : string list) : unit Lwt.t =
    match arguments with
    | [client_id; message] ->
      Lwt.catch (fun _ ->
        let client_id = Heap.Id.of_string client_id in
        (match Heap.find !State.clients client_id with
        | None -> Lwt.fail (Failure "Client socket not found.")
        | Some client ->
          let message = Base64.decode message in
          let length = String.length message in
          Lwt.bind (send client message 0 length) (fun _ ->
          print ("ClientSocketWrite " ^ id ^ " true"))))
        (fun _ -> print ("ClientSocketWrite " ^ id ^ " false"))
    | _ -> Lwt.fail (Failure "two arguments were expected")

  let close (id : string) (arguments : string list) : unit Lwt.t =
    match arguments with
    | [client_id] ->
      Lwt.catch (fun _ ->
        let client_id = Heap.Id.of_string client_id in
        (match Heap.find !State.clients client_id with
        | None -> Lwt.fail (Failure "Client socket not found.")
        | Some client ->
          State.clients := Heap.remove !State.clients client_id;
          let _ = Lwt_unix.close client in
          print ("ClientSocketClose " ^ id ^ " true")))
        (fun _ -> print ("ClientSocketClose " ^ id ^ " false"))
    | _ -> Lwt.fail (Failure "one argument was expected")
end

module ServerSocket = struct
  let rec accept_loop (id : string) (server : Lwt_unix.file_descr) : unit Lwt.t =
    Lwt.bind (Lwt_unix.accept server) (fun (client, _) ->
    let (client_id, clients) = Heap.add !State.clients client in
    State.clients := clients;
    Lwt.join [
      print ("ServerSocketBind " ^ id ^ " " ^ Heap.Id.to_string client_id);
      accept_loop id server ])

  let bind (id : string) (arguments : string list) : unit Lwt.t =
    match arguments with
    | [port] ->
      (match Big_int.big_int_of_string port with
      | exception Failure "int_of_string" ->
        Lwt.fail (Failure "the port number should be an integer")
      | port ->
        Lwt.catch (fun _ ->
          (match Big_int.int_of_big_int port with
          | exception Failure "int_of_big_int" ->
            Lwt.fail (Failure "the port number is too large to fit in an int")
          | port ->
            let socket = Lwt_unix.socket Lwt_unix.PF_INET Lwt_unix.SOCK_STREAM 0 in
            let address = Unix.ADDR_INET (Unix.inet_addr_any, port) in
            Lwt_unix.bind socket address;
            Lwt_unix.listen socket 5;
            accept_loop id socket))
          (fun _ -> print ("ServerSocketBind " ^ id ^ " ")))
    | _ -> Lwt.fail (Failure "one argument was expected")
end

module Time = struct
  let get (id : string) (arguments : string list) : unit Lwt.t =
    match arguments with
    | [] ->
      let time = int_of_float (Unix.time ()) in
      print ("Time " ^ id ^ " " ^ string_of_int time)
    | _ -> Lwt.fail (Failure "no arguments were expected")
end

let handle (message : string) : unit Lwt.t =
  match Str.split (Str.regexp_string " ") message with
  | command :: id :: arguments ->
    (match command with
    | "Log" -> Log.write id arguments
    | "FileRead" -> File.read id arguments
    | "ServerSocketBind" -> ServerSocket.bind id arguments
    | "ClientSocketRead" -> ClientSocket.read id arguments
    | "ClientSocketWrite" -> ClientSocket.write id arguments
    | "ClientSocketClose" -> ClientSocket.close id arguments
    | "Time" -> Time.get id arguments
    | _ -> Lwt.fail (Failure "unknown command"))
  | _ -> Lwt.fail (Failure "message too short")

let rec loop_on_inputs () : unit Lwt.t =
  Lwt.catch (fun () ->
    Lwt.bind (Lwt_io.read_line Lwt_io.stdin) (fun message ->
    Lwt.bind (
      if debug then
        print_error ("OUT: " ^ message)
      else
        Lwt.return ()) (fun _ ->
    Lwt.join [handle message; loop_on_inputs ()])))
    (function
      | End_of_file -> Lwt.return ()
      | e -> raise e)

let rec main () : unit Lwt.t =
  loop_on_inputs ()

;;Lwt_main.run (main ())
