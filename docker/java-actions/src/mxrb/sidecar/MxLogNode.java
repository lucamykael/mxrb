package mxrb.sidecar;

import java.io.PrintWriter;
import java.io.StringWriter;

import com.mendix.logging.ILogNode;
import com.mendix.logging.LogLevel;

/** A log node writing to the log of the Ruby application that runs the action. */
public final class MxLogNode implements ILogNode {
	private final String name;

	public MxLogNode(String name) {
		this.name = name;
	}

	@Override
	public String name() {
		return name;
	}

	@Override
	public boolean isDebugEnabled() {
		return true;
	}

	@Override
	public boolean isTraceEnabled() {
		return true;
	}

	@Override
	public void log(LogLevel level, Object message, Throwable error) {
		if (level == LogLevel.NONE) {
			return;
		}
		StringBuilder text = new StringBuilder(message == null ? "" : String.valueOf(message));
		if (error != null) {
			StringWriter trace = new StringWriter();
			error.printStackTrace(new PrintWriter(trace));
			text.append(text.length() == 0 ? "" : "\n").append(trace.toString().strip());
		}
		Bridge bridge = Bridge.peek();
		if (bridge == null) {
			System.err.println(name + " " + level + ": " + text);
		} else {
			bridge.call("log", "node", name, "level", level.name(), "message", text.toString());
		}
	}
}
