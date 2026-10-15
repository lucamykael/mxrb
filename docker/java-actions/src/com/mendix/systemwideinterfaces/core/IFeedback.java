package com.mendix.systemwideinterfaces.core;

/** Feedback a Java action gives the client. */
public interface IFeedback {
	/** The kind of a message shown to the user. */
	enum MessageType { INFO, WARNING, ERROR }

	/** Where a page opens. */
	enum FormTarget { CONTENT, WINDOW, MODAL }
}
