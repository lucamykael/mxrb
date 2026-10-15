package com.mendix.systemwideinterfaces;

/** A checked error of the Runtime API. */
public class MendixException extends Exception {
	public MendixException() { super(); }
	public MendixException(String message) { super(message); }
	public MendixException(Throwable cause) { super(cause); }
	public MendixException(String message, Throwable cause) { super(message, cause); }
}
