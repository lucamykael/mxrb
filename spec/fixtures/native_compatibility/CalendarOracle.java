// Optional direct oracle for the installed Mendix 11.12.1 expression functions.
// Run: java -cp "$MENDIX_HOME/runtime/bundles/*" CalendarOracle.java
// Supplies timezone/locale/calendar services only; no app, database or credentials.
import java.lang.reflect.*;
import java.util.*;
import com.mendix.languages.expressions.*;
import com.mendix.basis.value.*;
import com.mendix.systemwideinterfaces.core.*;
import scala.collection.immutable.Seq;
import scala.PartialFunction;

class MxrbCalendarOracle {
  static <T> T proxy(Class<T> type, java.util.function.Function<String,Object> handler) {
    return type.cast(Proxy.newProxyInstance(type.getClassLoader(), new Class<?>[]{type},
      (object, method, args) -> handler.apply(method.getName())));
  }
  static EvaluationContext context(String zone) {
    var session = proxy(ISession.class, name -> {
      if (name.equals("getTimeZone")) return TimeZone.getTimeZone(zone);
      if (name.equals("isSystemSession")) return false;
      throw new UnsupportedOperationException(name);
    });
    var context = proxy(com.mendix.basis.action.Context.class, name -> {
      if (name.equals("getSession")) return session;
      if (name.equals("calendarFactory")) return Proxy.newProxyInstance(
        com.mendix.modelstorage.time.CalendarFactory.class.getClassLoader(),
        new Class<?>[]{com.mendix.modelstorage.time.CalendarFactory.class},
        (o, m, a) -> Calendar.getInstance((TimeZone)a[0], (Locale)a[1]));
      throw new UnsupportedOperationException(name);
    });
    return proxy(EvaluationContext.class, name -> {
      if (name.equals("getContext")) return context;
      if (name.equals("locale")) return Locale.US;
      throw new UnsupportedOperationException(name);
    });
  }
  static MendixValue call(String name, String zone, MendixValue... values) throws Exception {
    var function = (PartialFunction<Seq<MendixValue>,MendixValue>) DateTimeFunctions.class
      .getMethod(name, EvaluationContext.class).invoke(null,context(zone));
    return function.apply(scala.jdk.javaapi.CollectionConverters.asScala(Arrays.asList(values)).toList());
  }
  static MendixValue date(String zone, long... parts) throws Exception {
    var values = Arrays.stream(parts).mapToObj(LongValue::new).toArray(MendixValue[]::new);
    return call("dateTime",zone,values);
  }
  static void output(String name, MendixValue value) {
    System.out.println(name + "\t" + ((DateTimeValue)value).value().toInstant());
  }
  public static void main(String[] args) throws Exception {
    String zone="America/New_York";
    output("spring",call("addDays",zone,date(zone,2024,3,9,12),new LongValue(1)));
    output("springGap",call("addDays",zone,date(zone,2024,3,9,2,30),new LongValue(1)));
    output("autumn",call("addDays",zone,date(zone,2024,11,2,1,30),new LongValue(1)));
    output("overlap",date(zone,2024,11,3,1,30));
    output("lordHowe",date("Australia/Lord_Howe",2024,10,6,2,15));
    output("apia",date("Pacific/Apia",2011,12,30,12));
    output("trimHours",call("trimToHours",zone,new DateTimeValue(Date.from(java.time.Instant.parse("2024-11-03T05:45:30Z")))));
    output("monthOverlap",call("addMonths",zone,date(zone,2024,10,3,1,30),new LongValue(1)));
    output("createGap",date(zone,2024,3,10,2,30));
    output("subtractDayGap",call("subtractDays",zone,date(zone,2024,3,11,2,30),new LongValue(1)));
    output("monthGap",call("addMonths",zone,date(zone,2024,2,10,2,30),new LongValue(1)));
    output("lordHoweDay",call("addDays","Australia/Lord_Howe",date("Australia/Lord_Howe",2024,10,5,2,15),new LongValue(1)));
    output("apiaDay",call("addDays","Pacific/Apia",date("Pacific/Apia",2011,12,29,12),new LongValue(1)));
    for(String function : new String[]{"trimToSeconds","trimToMinutes","trimToDays","trimToMonths","trimToYears"})
      output(function,call(function,zone,new DateTimeValue(Date.from(java.time.Instant.parse("2024-11-03T05:45:30.123Z")))));
    output("month",call("addMonths",zone,date(zone,2024,1,31,12),new LongValue(1)));
  }
}
