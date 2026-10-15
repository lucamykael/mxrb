package com.mendix.logging;

/** A message written to a log node. */
public class LogMessage {
	public final ILogNode node;
	public final LogLevel level;
	public final long timestamp;
	public final Object message;
	public final Throwable cause;

	public LogMessage(ILogNode node, LogLevel level, long timestamp, Object message, Throwable cause) {
		this.node = node;
		this.level = level;
		this.timestamp = timestamp;
		this.message = message;
		this.cause = cause;
	}
}
