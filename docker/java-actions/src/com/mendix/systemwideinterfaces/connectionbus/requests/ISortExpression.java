package com.mendix.systemwideinterfaces.connectionbus.requests;

/** A sorting of a request; an OQL query sorts with ORDER BY. */
public interface ISortExpression {
	/** Ascending or descending. */
	enum SortDirection { ASC, DESC }
}
