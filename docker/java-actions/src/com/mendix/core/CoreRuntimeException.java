package com.mendix.core;

import com.mendix.systemwideinterfaces.MendixRuntimeException;

/** An unchecked error raised by Core, such as a failing microflow call. */
public class CoreRuntimeException extends MendixRuntimeException {
	public CoreRuntimeException(String message) { super(message); }
	public CoreRuntimeException(String message, Throwable cause) { super(message, cause); }
	public CoreRuntimeException(Throwable cause) { super(cause); }
}
