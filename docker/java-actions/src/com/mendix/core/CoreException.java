package com.mendix.core;

import com.mendix.systemwideinterfaces.MendixException;

/** A checked error raised by Core. */
public class CoreException extends MendixException {
	public CoreException() { super(); }
	public CoreException(String message) { super(message); }
	public CoreException(Throwable cause) { super(cause); }
	public CoreException(String message, Throwable cause) { super(message, cause); }
}
