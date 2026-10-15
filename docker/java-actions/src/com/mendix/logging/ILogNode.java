package com.mendix.logging;

/** A named log node, written to the Ruby application's log. */
public interface ILogNode {
	String name();
	boolean isDebugEnabled();
	boolean isTraceEnabled();
	void log(LogLevel level, Object message, Throwable error);

	default void log(LogLevel level, Object message) { log(level, message, null); }
	default void log(LogLevel level, Throwable error) { log(level, null, error); }
	default void critical(Object message, Throwable error) { log(LogLevel.CRITICAL, message, error); }
	default void critical(Object message) { log(LogLevel.CRITICAL, message, null); }
	default void critical(Throwable error) { log(LogLevel.CRITICAL, null, error); }
	default void error(Object message, Throwable error) { log(LogLevel.ERROR, message, error); }
	default void error(Object message) { log(LogLevel.ERROR, message, null); }
	default void error(Throwable error) { log(LogLevel.ERROR, null, error); }
	default void warn(Object message, Throwable error) { log(LogLevel.WARNING, message, error); }
	default void warn(Object message) { log(LogLevel.WARNING, message, null); }
	default void warn(Throwable error) { log(LogLevel.WARNING, null, error); }
	default void info(Object message, Throwable error) { log(LogLevel.INFO, message, error); }
	default void info(Object message) { log(LogLevel.INFO, message, null); }
	default void info(Throwable error) { log(LogLevel.INFO, null, error); }
	default void debug(Object message, Throwable error) { log(LogLevel.DEBUG, message, error); }
	default void debug(Object message) { log(LogLevel.DEBUG, message, null); }
	default void debug(Throwable error) { log(LogLevel.DEBUG, null, error); }
	default void trace(Object message, Throwable error) { log(LogLevel.TRACE, message, error); }
	default void trace(Object message) { log(LogLevel.TRACE, message, null); }
	default void trace(Throwable error) { log(LogLevel.TRACE, null, error); }

	/** The Ruby application keeps the log, so a subscriber in the sidecar receives no messages. */
	default void subscribe(LogSubscriber subscriber, LogLevel level) { }
	default void unsubscribe(LogSubscriber subscriber) { }
	default void unsubscribe() { }
}
