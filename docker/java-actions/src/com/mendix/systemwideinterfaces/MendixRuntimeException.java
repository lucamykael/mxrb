package com.mendix.systemwideinterfaces;

/** An unchecked error of the Runtime API. */
public class MendixRuntimeException extends RuntimeException {
	public MendixRuntimeException() { super(); }
	public MendixRuntimeException(String message) { super(message); }
	public MendixRuntimeException(String message, Throwable cause) { super(message, cause); }
	public MendixRuntimeException(Throwable cause) { super(cause); }
}
