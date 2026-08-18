export const metadata = { title: "prototype" };

export default function RootLayout({ children }) {
  return (
    <html lang="en">
      <body
        style={{
          fontFamily: "ui-sans-serif, system-ui, sans-serif",
          margin: 0,
          padding: "2rem",
          lineHeight: 1.5,
        }}
      >
        {children}
      </body>
    </html>
  );
}
