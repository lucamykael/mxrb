package mxrb.sidecar;

import com.mendix.core.CoreRuntimeException;

/** An error the Ruby application raised while it answered a callback. */
public final class RubyException extends CoreRuntimeException {
	private final String type;

	public RubyException(String type, String message) {
		super(message);
		this.type = type;
	}

	public String type() {
		return type;
	}
}
