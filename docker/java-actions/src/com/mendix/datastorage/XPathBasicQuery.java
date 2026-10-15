package com.mendix.datastorage;

import java.math.BigDecimal;
import java.util.Date;
import java.util.List;

import com.mendix.systemwideinterfaces.core.IContext;
import com.mendix.systemwideinterfaces.core.IMendixIdentifier;
import com.mendix.systemwideinterfaces.core.IMendixObject;

/** An XPath retrieve with variables, a range and sortings. */
public interface XPathBasicQuery {
	XPathBasicQuery setAmount(int amount);
	XPathBasicQuery setOffset(int offset);
	XPathBasicQuery addSort(String path, boolean ascending);
	XPathBasicQuery setDepth(int depth);
	XPathBasicQuery setVariable(String name, BigDecimal value);
	XPathBasicQuery setVariable(String name, boolean value);
	XPathBasicQuery setVariable(String name, double value);
	XPathBasicQuery setVariable(String name, int value);
	XPathBasicQuery setVariable(String name, long value);
	XPathBasicQuery setVariable(String name, IMendixObject value);
	XPathBasicQuery setVariable(String name, IMendixIdentifier value);
	XPathBasicQuery setVariable(String name, String value);
	XPathBasicQuery setVariable(String name, Date value);
	List<IMendixObject> execute(IContext context);
	Long executeAggregateLong(IContext context);
	Double executeAggregateDouble(IContext context);
}
