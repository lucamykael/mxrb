// Optional helper oracle for the locally installed Mendix 11.12.1 runtime.
// Run: java -cp "$MENDIX_HOME/runtime/bundles/*" DecimalOracle.java
// Calls settings and DecimalUtils directly; this is not a full database/runtime boot.
import java.math.*;
import java.util.*;
import com.mendix.model.settings.*;
import com.mendix.shared.util.DecimalUtils;
class MxrbDecimalOracle {
  public static void main(String[] args) {
    var settings = new ModelRuntimeSettings(UUID.randomUUID(),scala.Option.empty(),scala.Option.empty(),scala.Option.empty(),ModelFirstDayOfWeekEnum.DEFAULT,"UTC","UTC",ModelHashAlgorithmType.BCRYPT,10,ModelRoundingMode.HALFUP,false,false,false,false,ModelSslCertificateAlgorithm.PKIX,8,null);
    System.out.println("model="+settings.decimalConfiguration());
    System.out.println("default="+DecimalUtils.DefaultDecimalConfiguration());
    for (String s: new String[]{"0.123456785","0.123456795","99999999999999999999.123456789","100000000000000000000","999999999999999999999999999999.12345678","1000000000000000000000000000000"})
      System.out.println(s+" -> "+DecimalUtils.roundDecimal(new BigDecimal(s),settings.decimalConfiguration()));
    System.out.println("division="+new BigDecimal(3).divide(new BigDecimal(7),settings.decimalMathContext()).toPlainString());
  }
}
