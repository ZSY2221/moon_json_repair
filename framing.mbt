///|
// A lightweight lexical scanner shared by extraction and streamed checkpoints.
// It retains framing only; the document parser remains the syntax authority.
priv enum FrameSignal {
  FrameContinues
  FrameClosed
  FrameMismatch
}

///|
priv enum FrameMode {
  FrameText
  FrameString(Char)
  FrameLineComment
  FrameBlockComment
}

///|
priv struct FrameScanner {
  closers : Array[Char]
  mut depth : Int32
  mut mode : FrameMode
  mut escaped : Bool
  mut pending_slash : Bool
  mut pending_star : Bool
  mut damaged : Bool
  depth_limit : Int32
}

///|
fn FrameScanner::new(depth_limit : Int32) -> FrameScanner {
  {
    closers: [],
    depth: 0,
    mode: FrameText,
    escaped: false,
    pending_slash: false,
    pending_star: false,
    damaged: false,
    depth_limit,
  }
}

///|
fn FrameScanner::feed(self : FrameScanner, letter : Char) -> FrameSignal {
  match self.mode {
    FrameString(quote) => {
      if self.escaped {
        self.escaped = false
      } else if letter == '\\' {
        self.escaped = true
      } else if letter == quote {
        self.mode = FrameText
        if self.depth == 0 {
          return FrameClosed
        }
      }
      return FrameContinues
    }
    FrameLineComment => {
      if letter is ('\r' | '\n') {
        self.mode = FrameText
      }
      return FrameContinues
    }
    FrameBlockComment => {
      if self.pending_star && letter == '/' {
        self.mode = FrameText
        self.pending_star = false
      } else {
        self.pending_star = letter == '*'
      }
      return FrameContinues
    }
    FrameText => ()
  }
  if self.pending_slash {
    self.pending_slash = false
    match letter {
      '/' => {
        self.mode = FrameLineComment
        return FrameContinues
      }
      '*' => {
        self.mode = FrameBlockComment
        return FrameContinues
      }
      _ => ()
    }
  }
  match letter {
    '"' | '\'' => self.mode = FrameString(letter)
    '/' => self.pending_slash = true
    '{' | '[' => {
      self.depth += 1
      if self.depth <= self.depth_limit {
        self.closers.push(if letter == '{' { '}' } else { ']' })
      } else {
        self.damaged = true
      }
    }
    '}' | ']' => {
      if self.depth <= self.depth_limit {
        if self.closers.last() != Some(letter) {
          self.damaged = true
          return FrameMismatch
        }
        ignore(self.closers.pop())
      }
      self.depth -= 1
      if self.depth == 0 {
        return FrameClosed
      }
    }
    _ => ()
  }
  FrameContinues
}
