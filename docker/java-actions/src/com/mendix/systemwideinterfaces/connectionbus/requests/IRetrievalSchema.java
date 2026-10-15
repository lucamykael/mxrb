package com.mendix.systemwideinterfaces.connectionbus.requests;

/** The range of rows a request retrieves. */
public interface IRetrievalSchema {
	long getOffset();
	void setOffset(long offset);
	long getAmount();
	void setAmount(long amount);
}
