package com.mendix.logging;

/** A receiver of log messages; the Ruby application keeps the log, so the sidecar sends it none. */
public abstract class LogSubscriber {
	private final String name;
	private final LogLevel level;

	protected LogSubscriber(String name, LogLevel level) {
		this.name = name;
		this.level = level;
	}

	public String getName() {
		return name;
	}

	public LogLevel getLogLevel() {
		return level;
	}

	public abstract void processMessage(LogMessage message);
}
