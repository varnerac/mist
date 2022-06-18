import gleam/bit_builder.{BitBuilder}
import gleam/bit_string
import gleam/http/request.{Request}
import gleam/http/response.{Response}
import gleam/list
import gleam/option.{None, Option, Some}
import gleam/otp/process.{Sender}
import gleam/result
import gleam/string
import glisten/tcp.{HandlerMessage, Socket}
import mist/encoder

// TODO:  need binary here as well
pub type Message {
  TextMessage(data: String)
}

pub type Handler =
  fn(Message, Sender(HandlerMessage)) -> Result(Nil, Nil)

// TODO:  there are other message types, AND ALSO will need to buffer across
// multiple frames, potentially
pub type Frame {
  // TODO:  should this include data?
  CloseFrame(payload_length: Int, payload: String)
  TextFrame(payload_length: Int, payload: String)
  // We don't care about basicaly everything else for now
  PingFrame(payload_length: Int, payload: String)
  PongFrame(payload_length: Int, payload: String)
}

external fn crypto_exor(a: BitString, b: BitString) -> BitString =
  "crypto" "exor"

fn unmask_data(
  data: BitString,
  masks: List(BitString),
  index: Int,
  resp: BitString,
) -> BitString {
  case data {
    <<>> -> resp
    <<masked:bit_string-size(8), rest:bit_string>> -> {
      assert Ok(mask_value) = list.at(masks, index % 4)
      let unmasked = crypto_exor(mask_value, masked)
      unmask_data(
        rest,
        masks,
        index + 1,
        <<resp:bit_string, unmasked:bit_string>>,
      )
    }
  }
}

pub fn frame_from_message(message: BitString) -> Result(Frame, Nil) {
  assert <<
    // TODO: handle this not being finished
    _fin:1,
    _reserved:3,
    opcode:int-size(4),
    1:1,
    payload_length:int-size(7),
    mask1:bit_string-size(8),
    mask2:bit_string-size(8),
    mask3:bit_string-size(8),
    mask4:bit_string-size(8),
    rest:bit_string,
  >> = message

  try data =
    rest
    |> unmask_data([mask1, mask2, mask3, mask4], 0, <<>>)
    |> bit_string.to_string

  case opcode {
    1 -> TextFrame(payload_length: payload_length, payload: data)
    8 -> CloseFrame(payload_length: payload_length, payload: data)
  }
  |> Ok
}

pub fn frame_to_bit_builder(frame: Frame) -> BitBuilder {
  case frame {
    TextFrame(payload_length, payload) | CloseFrame(payload_length, payload) -> {
      let fin = 1
      let mask_flag = 0
      let payload_bs = bit_string.from_string(payload)
      // TODO:  support extended payload length
      <<fin:1, 0:3, 1:4, mask_flag:1, payload_length:7, payload_bs:bit_string>>
      |> bit_builder.from_bit_string
    }
    PingFrame(..) -> bit_builder.from_bit_string(<<>>)
    PongFrame(payload_length, payload) -> {
      let payload_bs = bit_string.from_string(payload)
      <<1:1, 0:3, 10:4, 0:1, payload_length:7, payload_bs:bit_string>>
      |> bit_builder.from_bit_string
    }
  }
}

// TODO: improve this error type
pub fn upgrade(socket: Socket, req: Request(BitString)) -> Result(Nil, Nil) {
  try resp =
    upgrade_socket(req)
    |> result.replace_error(Nil)

  try _sent =
    resp
    |> encoder.to_bit_builder
    |> tcp.send(socket, _)
    |> result.replace_error(Nil)

  Ok(Nil)
}

pub fn to_text_frame(data: String) -> BitBuilder {
  let size =
    data
    |> bit_string.from_string
    |> bit_string.byte_size
  frame_to_bit_builder(TextFrame(size, data))
}

pub fn send(socket: Socket, data: String) -> Result(Nil, tcp.SocketReason) {
  data
  |> to_text_frame
  |> tcp.send(socket, _)
}

const websocket_key = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"

pub type ShaHash {
  Sha
}

pub external fn crypto_hash(hash: ShaHash, data: String) -> String =
  "crypto" "hash"

pub external fn base64_encode(data: String) -> String =
  "base64" "encode"

pub fn parse_key(key: String) -> String {
  key
  |> string.append(websocket_key)
  |> crypto_hash(Sha, _)
  |> base64_encode
}

pub fn upgrade_socket(
  req: Request(BitString),
) -> Result(Response(BitBuilder), Request(BitString)) {
  try _upgrade =
    request.get_header(req, "upgrade")
    |> result.replace_error(req)
  try key =
    request.get_header(req, "sec-websocket-key")
    |> result.replace_error(req)
  try _version =
    request.get_header(req, "sec-websocket-version")
    |> result.replace_error(req)

  let accept_key = parse_key(key)

  response.new(101)
  |> response.set_body(bit_builder.from_bit_string(<<"":utf8>>))
  |> response.prepend_header("Upgrade", "websocket")
  |> response.prepend_header("Connection", "Upgrade")
  |> response.prepend_header("Sec-WebSocket-Accept", accept_key)
  |> Ok
}

pub fn echo_handler(
  msg: Message,
  sender: Sender(HandlerMessage),
) -> Result(Nil, Nil) {
  let _ = process.send(sender, tcp.SendMessage(to_text_frame(msg.data)))

  Ok(Nil)
}

pub type WebsocketHandler {
  WebsocketHandler(
    on_close: Option(fn(Sender(tcp.HandlerMessage)) -> Nil),
    on_init: Option(fn(Sender(tcp.HandlerMessage)) -> Nil),
    handler: Handler,
  )
}

pub fn with_handler(func: Handler) -> WebsocketHandler {
  WebsocketHandler(on_close: None, on_init: None, handler: func)
}

pub fn on_init(
  handler: WebsocketHandler,
  func: fn(Sender(tcp.HandlerMessage)) -> Nil,
) -> WebsocketHandler {
  WebsocketHandler(..handler, on_init: Some(func))
}

pub fn on_close(
  handler: WebsocketHandler,
  func: fn(Sender(tcp.HandlerMessage)) -> Nil,
) -> WebsocketHandler {
  WebsocketHandler(..handler, on_close: Some(func))
}
