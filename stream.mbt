///|
/// Buffers a bounded stream and takes repair snapshots of the current prefix.
/// A snapshot never modifies the prefix. Each preview reparses that prefix.
pub struct RepairStream {
  priv buffer : StringBuilder
  priv limits : RepairLimits
  priv mut size : Int32
}

///|
pub fn RepairStream::new(
  limits~ : RepairLimits = RepairLimits::default(),
) -> RepairStream {
  { buffer: StringBuilder(), limits: limits.normalized(), size: 0, }
}

///|
/// Append a chunk atomically. On overflow the previously accepted prefix
/// remains available to preview, extend, or reset.
pub fn RepairStream::push(
  self : RepairStream,
  chunk : String,
) -> Result[Unit, RepairError] {
  if chunk.length() > self.limits.max_input - self.size {
    let cursor = Cursor::new(self.buffer.to_string()[:], self.limits)
    cursor.advance(self.size)
    return Err(input_limit_error(cursor.position))
  }
  self.buffer.write_string(chunk)
  self.size += chunk.length()
  Ok(())
}

///|
pub fn RepairStream::preview(
  self : RepairStream,
) -> Result[RepairReport, RepairError] {
  repair(self.buffer.to_string(), limits=self.limits)
}

///|
pub fn RepairStream::reset(self : RepairStream) -> Unit {
  self.buffer.reset(keep_capacity=false)
  self.size = 0
}
